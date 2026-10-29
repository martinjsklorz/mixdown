import Foundation
import MixdownCore

/// Reads the notes in a folder for browsing.
public enum NoteLibrary {
    static let fileExtensions: Set<String> = ["md", "markdown"]

    /// Every Markdown file in `directory` and its subfolders, newest first. Hidden files and
    /// folders (like Obsidian's `.obsidian` and `.trash`) and packages are skipped, and a folder
    /// that doesn't exist yet has no notes. Only reads the files that are new or changed since
    /// `cache` last saw them, and updates `cache`.
    public static func loadNotes(in directory: URL, cache: inout Cache) throws -> [NoteDocument] {
        var entries: [URL: Cache.Entry] = [:]
        for file in try noteFiles(in: directory) {
            let stamp = Cache.Stamp(file.values)
            if let entry = cache.entries[file.url], entry.stamp == stamp {
                entries[file.url] = entry
                continue
            }
            guard let data = try? Data(contentsOf: file.url) else { continue }
            var note = NoteDocument(
                url: file.url,
                contents: String(decoding: data, as: UTF8.self),
                fileDate: file.values.creationDate ?? file.values.contentModificationDate ?? .distantPast
            )
            note.folder = file.folder
            // Worked out here, off the main thread, and kept with the note.
            _ = NoteSearchIndex.fingerprint(of: note)
            entries[file.url] = Cache.Entry(stamp: stamp, note: note)
        }
        cache.entries = entries

        // The file name breaks ties so the order is stable between reloads.
        return entries.values.map(\.note).sorted {
            ($0.createdAt, $0.url.lastPathComponent) > ($1.createdAt, $1.url.lastPathComponent)
        }
    }

    /// The resource values `noteFiles(in:)` reads of each file.
    private static let fileKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isPackageKey, .creationDateKey, .contentModificationDateKey,
        .fileSizeKey,
    ]

    /// The files `loadNotes(in:cache:)` reads as notes, in no particular order, each with the
    /// subfolder it's in, as `NoteDocument.folder` has it, and its `fileKeys`. A folder that
    /// doesn't exist yet has none. Throws only if `directory` itself can't be read.
    static func noteFiles(in directory: URL) throws -> [(url: URL, folder: String?, values: URLResourceValues)] {
        let fileManager = FileManager.default
        var files: [(url: URL, folder: String?, values: URLResourceValues)] = []
        guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { return files }
        // Folders still to read, with their paths relative to `directory`.
        var folders: [(url: URL, path: String?)] = [(directory, nil)]
        while let folder = folders.popLast() {
            let urls: [URL]
            do {
                urls = try fileManager.contentsOfDirectory(
                    at: folder.url,
                    includingPropertiesForKeys: Array(fileKeys),
                    options: [.skipsHiddenFiles]
                )
            } catch {
                // Only the notes folder itself has to be readable.
                if folder.path == nil { throw error }
                continue
            }
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: fileKeys) else { continue }
                // Symbolic links aren't followed, so a link to a parent folder can't loop.
                if values.isDirectory == true, values.isPackage != true {
                    let name = url.lastPathComponent
                    folders.append((url, folder.path.map { "\($0)/\(name)" } ?? name))
                    continue
                }
                guard isNote(url), values.isRegularFile == true else { continue }
                files.append((url, folder.path, values))
            }
        }
        return files
    }

    /// The notes of `notes` that match `query`, for the sidebar's search, each with the line of its
    /// text that matches best, or `""` if only its title or folder does. A note matches if every
    /// one of `searchTerms(in: query)` is in its title, text or folder, ignoring case and accents.
    /// Its text is the plain text of `NoteSearchIndex.lines(of:)`, like Spotlight has it: without
    /// Markdown's escapes and markup, and without the headings every note has.
    /// Looking through long transcripts takes a while, so it's meant to run off the main thread,
    /// and throws `CancellationError` as soon as it's cancelled.
    public static func search(_ notes: [NoteDocument], for query: String) throws -> [NoteDocument.ID: String] {
        let terms = searchTerms(in: query)
        guard !terms.isEmpty else { return [:] }
        var matches: [NoteDocument.ID: String] = [:]
        for note in notes {
            try Task.checkCancellation()
            let lines = NoteSearchIndex.lines(of: note)
            let inBody = terms.filter { term in lines.contains { $0.text.localizedStandardContains(term) } }
            let matchesAll = terms.allSatisfy { term in
                inBody.contains(term) || note.title.localizedStandardContains(term)
                    || note.folder?.localizedStandardContains(term) == true
            }
            guard matchesAll else { continue }
            matches[note.id] = inBody.isEmpty ? "" : excerpt(of: note, terms: inBody)
        }
        return matches
    }

    /// What `search(_:for:)` looks for in `query`: each word, and text in double quotes as it is.
    public static func searchTerms(in query: String) -> [String] {
        var terms: [String] = []
        for (index, part) in query.split(separator: "\"", omittingEmptySubsequences: false).enumerated() {
            // Every other part is in quotes, including an unclosed one at the end.
            if index.isMultiple(of: 2) {
                terms += part.split(whereSeparator: \.isWhitespace).map(String.init)
            } else {
                let phrase = part.collapsingWhitespace
                if !phrase.isEmpty { terms.append(phrase) }
            }
        }
        // Each once, as typed first.
        var seen = Set<String>()
        return terms.filter {
            seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)).inserted
        }
    }

    /// Most characters of an excerpt before the first term found in it.
    static let excerptLeadLength = 30

    /// The line of `note`'s text, as `NoteSearchIndex.lines(of:)` has it, with the most of `terms`,
    /// the first of them if several tie. Starts a little before the first term it has, with an
    /// ellipsis, if that's far into the line. `""` if no line has any.
    static func excerpt(of note: NoteDocument, terms: [String]) -> String {
        var best: (line: String, count: Int)?
        for line in NoteSearchIndex.lines(of: note) {
            let count = terms.count { line.text.localizedStandardContains($0) }
            if count > best?.count ?? 0 { best = (line.text, count) }
            if count == terms.count { break }
        }
        guard let line = best?.line else { return "" }
        let first = terms.compactMap { line.localizedStandardRange(of: $0)?.lowerBound }.min()
        guard let first, line.distance(from: line.startIndex, to: first) > excerptLeadLength else { return line }
        var start = line.index(first, offsetBy: -excerptLeadLength)
        // From the start of a word.
        if let space = line[start..<first].firstIndex(where: \.isWhitespace) {
            start = line.index(after: space)
        }
        return "…" + line[start...]
    }

    /// The notes `loadNotes(in:cache:)` read last time, by file, so it can skip the ones whose
    /// files haven't changed.
    public struct Cache: Sendable {
        /// What tells a changed file apart: a note is read again if either differs.
        struct Stamp: Equatable, Sendable {
            var modificationDate: Date?
            var size: Int?

            init(_ values: URLResourceValues) {
                modificationDate = values.contentModificationDate
                size = values.fileSize
            }
        }

        struct Entry: Sendable {
            var stamp: Stamp
            var note: NoteDocument
        }

        var entries: [URL: Entry] = [:]

        public init() {}
    }

    /// The space the notes `loadNotes(in:cache:)` would list take up: Markdown files only, so
    /// other files in a shared folder (an Obsidian vault's attachments, say) aren't counted.
    public static func diskUsage(in directory: URL) -> DiskUsage {
        DiskUsage.of(directory, options: [.skipsHiddenFiles, .skipsPackageDescendants], including: isNote)
    }

    /// Whether the file at `url` would be listed as a note, judged by its name alone: a Markdown
    /// file that isn't hidden.
    private static func isNote(_ url: URL) -> Bool {
        !url.lastPathComponent.hasPrefix(".") && fileExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether a change to the item at `url` can change the notes listed for `directory`: it's a
    /// note or a folder (renaming or removing one moves every note in it), and neither it nor a
    /// folder it's in is hidden. Judged by the path alone, for a folder watcher.
    public static func affectsNotes(_ url: URL, isDirectory: Bool, in directory: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        let root = directory.standardizedFileURL.pathComponents
        // A path outside `directory` (one spelled differently, say) is judged by its name only.
        let relative = components.starts(with: root) ? components.dropFirst(root.count) : components.suffix(1)
        if relative.contains(where: { $0.hasPrefix(".") }) { return false }
        return isDirectory || isNote(url)
    }

    /// Changes the title of the note at `url` and renames its file to match. Returns the new URL.
    ///
    /// See `NoteDocument.retitled(_:url:to:)` for how the contents change. The file keeps its
    /// `yyyy-MM-dd HHmm ` prefix and extension, and gets ` 2`, ` 3`, … if the new name is taken.
    /// Runs of whitespace in the title become one space, and a blank title becomes "Untitled".
    /// A note that isn't valid UTF-8 is left alone: writing it back would garble it.
    public static func rename(noteAt url: URL, to title: String) throws -> URL {
        var title = title.collapsingWhitespace
        if title.isEmpty { title = "Untitled" }

        try rewrite(noteAt: url) { NoteDocument.retitled($0, url: url, to: title) }

        let stem = url.deletingPathExtension().lastPathComponent
        let prefix = stem.range(of: #"^\d{4}-\d{2}-\d{2} \d{4} "#, options: .regularExpression).map { stem[$0] }
        return try move(
            url,
            into: url.deletingLastPathComponent(),
            named: (prefix ?? "") + MarkdownNoteWriter.sanitizedTitle(title),
            pathExtension: url.pathExtension
        )
    }

    /// Pins the note at `url`, listing it above the others, or unpins it. See
    /// `NoteDocument.pinned(_:_:)` for how the contents change. A note that isn't valid UTF-8 is
    /// left alone, like by `rename(noteAt:to:)`.
    public static func setPinned(_ isPinned: Bool, noteAt url: URL) throws {
        try rewrite(noteAt: url) { NoteDocument.pinned($0, isPinned) }
    }

    /// Renames the speaker `old` in the note at `url` to `new`, which is trimmed and has runs of
    /// whitespace collapsed. See `NoteDocument.renamingSpeaker(_:from:to:)` for how the contents
    /// change. Returns whether the note changed; a blank name changes nothing. A note that isn't
    /// valid UTF-8 is left alone, like by `rename(noteAt:to:)`.
    @discardableResult
    public static func renameSpeaker(_ old: String, to new: String, inNoteAt url: URL) throws -> Bool {
        let new = new.collapsingWhitespace
        return try rewriteIfChanged(noteAt: url) { NoteDocument.renamingSpeaker($0, from: old, to: new) }
    }

    /// Applies `vocabulary` to every note in `directory` and its subfolders, as listed by
    /// `loadNotes(in:cache:)`. See `NoteDocument.corrected(_:by:)` for what changes; file names
    /// stay as they are. A note that can't be read or written is skipped, and the others are
    /// still corrected; so is one deleted while the others are corrected.
    public static func applyVocabulary(
        _ vocabulary: Vocabulary,
        toNotesIn directory: URL
    ) throws
        -> VocabularyChanges
    {
        let correction = NoteDocument.VocabularyCorrection(vocabulary)
        var changes = VocabularyChanges()
        guard !correction.isEmpty else { return changes }
        // In a stable order: newest first for the dated names Mixdown gives notes.
        let urls = try noteFiles(in: directory).map(\.url).sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in urls {
            do {
                if try rewriteIfChanged(noteAt: url, { NoteDocument.corrected($0, by: correction) }) {
                    changes.correctedNotes.append(url)
                }
            } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
                continue
            } catch {
                changes.failures.append(.init(url: url, message: error.localizedDescription))
            }
        }
        return changes
    }

    /// What `applyVocabulary(_:toNotesIn:)` did.
    public struct VocabularyChanges: Sendable, Equatable {
        public struct Failure: Sendable, Equatable {
            public var url: URL
            public var message: String
        }

        /// The notes that had words replaced.
        public var correctedNotes: [URL] = []
        /// The notes that couldn't be read or written.
        public var failures: [Failure] = []
    }

    /// How many times `rewriteIfChanged(noteAt:_:)` reads a note that changed while it was being
    /// rewritten before it gives up.
    static let maxRewriteAttempts = 3

    /// Like `rewrite(noteAt:_:)`, but leaves the file alone when `transform` returns `nil`.
    /// Returns whether it was rewritten.
    ///
    /// If the file changes between reading and writing it back, by another app or a sync, it's
    /// read and transformed again, so that change isn't lost, and after `maxRewriteAttempts`
    /// it throws. A file deleted meanwhile isn't written back. Mixdown's own changes don't get
    /// here at once: they go through `NoteFileEditor` one at a time.
    static func rewriteIfChanged(noteAt url: URL, _ transform: (String) -> String?) throws -> Bool {
        for _ in 0..<maxRewriteAttempts {
            // Before reading, so a change made while reading counts as one.
            let stamp = try stamp(ofNoteAt: url)
            guard let contents = transform(try contents(ofNoteAt: url)) else { return false }
            if try replaceContents(ofNoteAt: url, with: contents, ifStill: stamp) { return true }
        }
        throw KeptChangingError(url: url)
    }

    /// Replaces the contents of the note at `url` with what `transform` makes of them.
    private static func rewrite(noteAt url: URL, _ transform: (String) -> String) throws {
        _ = try rewriteIfChanged(noteAt: url) { transform($0) }
    }

    /// Thrown when a note kept changing while it was being rewritten.
    struct KeptChangingError: LocalizedError {
        var url: URL

        var errorDescription: String? {
            "“\(url.deletingPathExtension().lastPathComponent)” kept changing while Mixdown was saving it."
        }
    }

    /// What `rewriteIfChanged(noteAt:_:)` checks to tell whether a file changed.
    private static func stamp(ofNoteAt url: URL) throws -> Cache.Stamp {
        var url = url
        // A URL keeps the values it read, which would hide a change.
        url.removeAllCachedResourceValues()
        return Cache.Stamp(try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]))
    }

    private static func contents(ofNoteAt url: URL) throws -> String {
        guard let contents = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSURLErrorKey: url])
        }
        return contents
    }

    /// Replaces the contents of the note at `url` with `contents`, unless the file no longer has
    /// `stamp`. Returns whether it did. Throws if the file is gone.
    private static func replaceContents(
        ofNoteAt url: URL,
        with contents: String,
        ifStill stamp: Cache.Stamp
    ) throws
        -> Bool
    {
        let fileManager = FileManager.default
        let temporaryURL = MarkdownNoteWriter.temporaryURL(in: url.deletingLastPathComponent())
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try Data(contents.utf8).write(to: temporaryURL)
        // Checked last, to leave as little time as can be for another change to slip in.
        guard try self.stamp(ofNoteAt: url) == stamp else { return false }
        // Swaps the contents in atomically while keeping the file's creation date, which dates
        // notes without a `created` field.
        _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        return true
    }

    /// Moves a note that was moved to the Trash back to where it was. If a note with its old name
    /// has appeared since, it gets ` 2`, ` 3`, … Returns where it ends up.
    public static func restore(trashedAt trashedURL: URL, to originalURL: URL) throws -> URL {
        let directory = originalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try move(
            trashedURL,
            into: directory,
            named: originalURL.deletingPathExtension().lastPathComponent,
            pathExtension: originalURL.pathExtension
        )
    }

    /// Writes a note's `contents` back to where it was, like `restore(trashedAt:to:)`, for when
    /// the file in the Trash can't be moved.
    public static func restore(contents: Data, to originalURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let directory = originalURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = MarkdownNoteWriter.temporaryURL(in: directory)
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try contents.write(to: temporaryURL)
        return try move(
            temporaryURL,
            into: directory,
            named: originalURL.deletingPathExtension().lastPathComponent,
            pathExtension: originalURL.pathExtension
        )
    }

    /// Moves the file at `url` into `directory` as `stem` and `pathExtension`, or with ` 2`,
    /// ` 3`, … if that name is taken by another file.
    private static func move(_ url: URL, into directory: URL, named stem: String, pathExtension: String) throws -> URL {
        let fileManager = FileManager.default
        let name = url.lastPathComponent
        let source = url.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
        let isSameDirectory = source == directory.standardizedFileURL.path(percentEncoded: false)
        return try MarkdownNoteWriter.withFreeName(stem: stem, pathExtension: pathExtension) { candidate in
            if isSameDirectory && candidate == name { return url }
            let destination = directory.appending(path: candidate, directoryHint: .notDirectory)
            // On a case-insensitive volume, a name that differs only in case is the file itself.
            let changesCaseOnly = isSameDirectory && candidate.caseInsensitiveCompare(name) == .orderedSame
            if !changesCaseOnly, fileManager.fileExists(atPath: destination.path(percentEncoded: false)) { return nil }
            if changesCaseOnly {
                // Moving straight to the new name may count as overwriting the file itself.
                let temporaryURL = MarkdownNoteWriter.temporaryURL(in: directory)
                try fileManager.moveItem(at: url, to: temporaryURL)
                do {
                    try fileManager.moveItem(at: temporaryURL, to: destination)
                } catch {
                    try? fileManager.moveItem(at: temporaryURL, to: url)
                    throw error
                }
            } else {
                try fileManager.moveItem(at: url, to: destination)
            }
            return destination
        }
    }
}
