import Foundation
import MixdownCore

/// Writes notes as Markdown files named `yyyy-MM-dd HHmm <title>.md` into a directory.
///
/// The file appears atomically and an existing note is never overwritten: on a name
/// collision the writer appends ` 2`, ` 3`, … to the file name.
public struct MarkdownNoteWriter: NoteWriting {
    static let maxTitleLength = 80
    static let maxCollisionSuffix = 999
    /// File names may have 255 bytes, which APFS counts in decomposed UTF-8. The rest goes to
    /// the date, a collision suffix and the extension.
    static let maxTitleBytes = 255 - "yyyy-MM-dd HHmm ".utf8.count - " \(maxCollisionSuffix).md".utf8.count

    let directory: URL

    /// - Parameter directory: Destination folder. Created on first write if missing.
    public init(directory: URL) {
        self.directory = directory
    }

    public func write(_ note: Note) async throws -> URL {
        // `FileManager.default` is thread-safe; not storing one keeps the writer trivially Sendable.
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Write to a hidden temp file in the same directory, then move it into place. The move
        // is an atomic rename and fails instead of replacing an existing file.
        let temporaryURL = Self.temporaryURL(in: directory)
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try Data(MarkdownNoteRenderer.render(note).utf8).write(to: temporaryURL)

        return try Self.withFreeName(stem: Self.fileNameStem(for: note), pathExtension: "md") { name in
            let destination = directory.appending(path: name, directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) { return nil }
            try fileManager.moveItem(at: temporaryURL, to: destination)
            return destination
        }
    }

    /// A hidden file name in `directory` to write to before moving the file into place.
    static func temporaryURL(in directory: URL) -> URL {
        directory.appending(path: ".\(UUID().uuidString).mixdown-tmp", directoryHint: .notDirectory)
    }

    /// Calls `attempt` with `stem.pathExtension`, then `stem 2.pathExtension`, `stem 3…`, up to
    /// `maxCollisionSuffix`, until it returns a URL; it returns `nil` for a name that's taken.
    /// Throwing `CocoaError.fileWriteFileExists` moves on too: another file got the name first.
    /// Throws that error itself once every name is taken.
    static func withFreeName(
        stem: String,
        pathExtension: String,
        _ attempt: (_ name: String) throws -> URL?
    ) throws -> URL {
        for index in 1...maxCollisionSuffix {
            var name = index == 1 ? stem : "\(stem) \(index)"
            if !pathExtension.isEmpty { name += ".\(pathExtension)" }
            do {
                if let url = try attempt(name) { return url }
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue  // Lost a race with another file; try the next suffix.
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    // MARK: - File names

    private static func fileNameStem(for note: Note) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "\(formatter.string(from: note.createdAt)) \(sanitizedTitle(note.title))"
    }

    /// Replaces path separators, `:` and `|` with `-` and square brackets with parentheses, drops
    /// `#` and `^`, turns control characters into spaces, collapses whitespace, drops leading
    /// dots, which would hide the file, and caps the length in characters and bytes.
    ///
    /// `# ^ [ ] |` are allowed in file names but break `[[wiki links]]` to the note in Obsidian,
    /// which won't create a file with them either.
    static func sanitizedTitle(_ title: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            switch scalar {
            case "/", ":", "\\", "|":
                scalars.append("-")
            case "[":
                scalars.append("(")
            case "]":
                scalars.append(")")
            case "#", "^":
                break
            default:
                scalars.append(scalar.properties.generalCategory == .control ? " " : scalar)
            }
        }
        var result = String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        result = String(result.drop { $0 == "." || $0.isWhitespace })
        if result.count > maxTitleLength {
            result = String(result.prefix(maxTitleLength))
        }
        // Drops whole characters, so no cluster or scalar is cut in half.
        while result.decomposedStringWithCanonicalMapping.utf8.count > maxTitleBytes {
            result.removeLast()
        }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "Untitled" : result
    }
}
