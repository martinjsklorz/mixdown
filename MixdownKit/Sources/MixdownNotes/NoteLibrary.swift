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
            guard fileExtensions.contains(url.pathExtension.lowercased()),
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
}
