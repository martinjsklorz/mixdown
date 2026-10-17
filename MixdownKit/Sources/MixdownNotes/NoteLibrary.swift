import Foundation

/// Reads the notes in a folder for browsing.
public enum NoteLibrary {
    static let fileExtensions: Set<String> = ["md", "markdown"]

    /// Every Markdown file directly inside `directory`, newest first. Hidden files and
    /// subfolders are skipped, and a folder that doesn't exist yet has no notes.
    public static func loadNotes(in directory: URL) throws -> [NoteDocument] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey]
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        let notes = urls.compactMap { url -> NoteDocument? in
            guard isNote(url),
                let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true,
                let data = try? Data(contentsOf: url)
            else { return nil }
            return NoteDocument(
                url: url,
                contents: String(decoding: data, as: UTF8.self),
                fileDate: values.creationDate ?? values.contentModificationDate ?? .distantPast
            )
        }
        // The file name breaks ties so the order is stable between reloads.
        return notes.sorted {
            ($0.createdAt, $0.url.lastPathComponent) > ($1.createdAt, $1.url.lastPathComponent)
        }
    }

    /// Whether the file at `url` would be listed as a note, judged by its name alone: a Markdown
    /// file that isn't hidden. Lets a folder watcher skip changes to `.DS_Store` and editors'
    /// temporary files.
    public static func isNote(_ url: URL) -> Bool {
        !url.lastPathComponent.hasPrefix(".") && fileExtensions.contains(url.pathExtension.lowercased())
    }

    /// Changes the title of the note at `url` and renames its file to match. Returns the new URL.
    ///
    /// See `NoteDocument.retitled(_:url:to:)` for how the contents change. The file keeps its
    /// `yyyy-MM-dd HHmm ` prefix and extension, and gets ` 2`, ` 3`, … if the new name is taken.
    /// A blank title becomes "Untitled".
    public static func rename(noteAt url: URL, to title: String) throws -> URL {
        let fileManager = FileManager.default
        var title = MarkdownNoteRenderer.singleLine(title)
        if title.isEmpty { title = "Untitled" }

        let contents = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        let temporaryURL = url.deletingLastPathComponent().appending(
            path: ".\(UUID().uuidString).mixdown-tmp",
            directoryHint: .notDirectory
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try Data(NoteDocument.retitled(contents, url: url, to: title).utf8).write(to: temporaryURL)
        // Swaps the contents in atomically while keeping the file's creation date, which dates
        // notes without a `created` field.
        _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)

        let stem = url.deletingPathExtension().lastPathComponent
        let prefix = stem.range(of: #"^\d{4}-\d{2}-\d{2} \d{4} "#, options: .regularExpression).map { stem[$0] }
        return try move(
            url,
            into: url.deletingLastPathComponent(),
            named: (prefix ?? "") + MarkdownNoteWriter.sanitizedTitle(title),
            pathExtension: url.pathExtension
        )
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
        let temporaryURL = directory.appending(
            path: ".\(UUID().uuidString).mixdown-tmp",
            directoryHint: .notDirectory
        )
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
        for index in 1...MarkdownNoteWriter.maxCollisionSuffix {
            var candidate = index == 1 ? stem : "\(stem) \(index)"
            if !pathExtension.isEmpty { candidate += ".\(pathExtension)" }
            if isSameDirectory && candidate == name { return url }
            let destination = directory.appending(path: candidate, directoryHint: .notDirectory)
            // On a case-insensitive volume, a name that differs only in case is the file itself.
            let changesCaseOnly = isSameDirectory && candidate.caseInsensitiveCompare(name) == .orderedSame
            if !changesCaseOnly, fileManager.fileExists(atPath: destination.path(percentEncoded: false)) { continue }
            do {
                if changesCaseOnly {
                    // Moving straight to the new name may count as overwriting the file itself.
                    let temporaryURL = directory.appending(
                        path: ".\(UUID().uuidString).mixdown-tmp",
                        directoryHint: .notDirectory
                    )
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
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue  // Lost a race with another file; try the next suffix.
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
