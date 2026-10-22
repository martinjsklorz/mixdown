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
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else {
            cache = Cache()
            return []
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isPackageKey, .creationDateKey, .contentModificationDateKey,
            .fileSizeKey,
        ]
        var entries: [URL: Cache.Entry] = [:]
        // Folders still to read, with their paths relative to `directory`.
        var folders: [(url: URL, path: String?)] = [(directory, nil)]
        while let folder = folders.popLast() {
            let urls: [URL]
            do {
                urls = try fileManager.contentsOfDirectory(
                    at: folder.url,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                )
            } catch {
                // Only the notes folder itself has to be readable.
                if folder.path == nil { throw error }
                continue
            }
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                // Symbolic links aren't followed, so a link to a parent folder can't loop.
                if values.isDirectory == true, values.isPackage != true {
                    let name = url.lastPathComponent
                    folders.append((url, folder.path.map { "\($0)/\(name)" } ?? name))
                    continue
                }
                guard isNote(url), values.isRegularFile == true else { continue }
                let stamp = Cache.Stamp(values)
                if let entry = cache.entries[url], entry.stamp == stamp {
                    entries[url] = entry
                    continue
                }
                guard let data = try? Data(contentsOf: url) else { continue }
                var note = NoteDocument(
                    url: url,
                    contents: String(decoding: data, as: UTF8.self),
                    fileDate: values.creationDate ?? values.contentModificationDate ?? .distantPast
                )
                note.folder = folder.path
                entries[url] = Cache.Entry(stamp: stamp, note: note)
            }
        }
        cache.entries = entries

        // The file name breaks ties so the order is stable between reloads.
        return entries.values.map(\.note).sorted {
            ($0.createdAt, $0.url.lastPathComponent) > ($1.createdAt, $1.url.lastPathComponent)
        }
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
        var title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
        let new = new.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return try rewriteIfChanged(noteAt: url) { NoteDocument.renamingSpeaker($0, from: old, to: new) }
    }

    /// Applies `vocabulary` to every note in `directory` and its subfolders, as listed by
    /// `loadNotes(in:cache:)`. See `NoteDocument.corrected(_:by:)` for what changes; file names
    /// stay as they are. A note that can't be read or written is skipped, and the others are
    /// still corrected.
    public static func applyVocabulary(
        _ vocabulary: Vocabulary,
        toNotesIn directory: URL
    ) throws
        -> VocabularyChanges
    {
        let correction = NoteDocument.VocabularyCorrection(vocabulary)
        var changes = VocabularyChanges()
        guard !correction.isEmpty else { return changes }
        var cache = Cache()
        for note in try loadNotes(in: directory, cache: &cache) {
            do {
                if try rewriteIfChanged(noteAt: note.url, { NoteDocument.corrected($0, by: correction) }) {
                    changes.correctedNotes.append(note.url)
                }
            } catch {
                changes.failures.append(.init(url: note.url, message: error.localizedDescription))
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

    /// Like `rewrite(noteAt:_:)`, but leaves the file alone when `transform` returns `nil`.
    /// Returns whether it was rewritten.
    private static func rewriteIfChanged(noteAt url: URL, _ transform: (String) -> String?) throws -> Bool {
        guard let contents = transform(try contents(ofNoteAt: url)) else { return false }
        try replaceContents(ofNoteAt: url, with: contents)
        return true
    }

    /// Replaces the contents of the note at `url` with what `transform` makes of them.
    private static func rewrite(noteAt url: URL, _ transform: (String) -> String) throws {
        try replaceContents(ofNoteAt: url, with: transform(try contents(ofNoteAt: url)))
    }

    private static func contents(ofNoteAt url: URL) throws -> String {
        guard let contents = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSURLErrorKey: url])
        }
        return contents
    }

    private static func replaceContents(ofNoteAt url: URL, with contents: String) throws {
        let fileManager = FileManager.default
        let temporaryURL = MarkdownNoteWriter.temporaryURL(in: url.deletingLastPathComponent())
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try Data(contents.utf8).write(to: temporaryURL)
        // Swaps the contents in atomically while keeping the file's creation date, which dates
        // notes without a `created` field.
        _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
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
