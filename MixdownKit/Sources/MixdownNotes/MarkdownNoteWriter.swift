import Foundation
import MixdownCore

/// Writes notes as Markdown files named `yyyy-MM-dd HHmm <title>.md` into a directory.
///
/// The file appears atomically and an existing note is never overwritten: on a name
/// collision the writer appends ` 2`, ` 3`, … to the file name.
public struct MarkdownNoteWriter: NoteWriting {
    static let maxTitleLength = 80
    static let maxCollisionSuffix = 999

    public let directory: URL

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
        let temporaryURL = directory.appending(
            path: ".\(UUID().uuidString).mixdown-tmp",
            directoryHint: .notDirectory
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try Data(MarkdownNoteRenderer.render(note).utf8).write(to: temporaryURL)

        let stem = Self.fileNameStem(for: note)
        for index in 1...Self.maxCollisionSuffix {
            let name = index == 1 ? "\(stem).md" : "\(stem) \(index).md"
            let destination = directory.appending(path: name, directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) { continue }
            do {
                try fileManager.moveItem(at: temporaryURL, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue  // Lost a race with another writer; try the next suffix.
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    // MARK: - File names

    static func fileNameStem(for note: Note, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "\(formatter.string(from: note.createdAt)) \(sanitizedTitle(note.title))"
    }

    /// Replaces path separators and `:` with `-`, turns control characters into spaces,
    /// collapses whitespace and caps the length.
    static func sanitizedTitle(_ title: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            switch scalar {
            case "/", ":", "\\":
                scalars.append("-")
            default:
                scalars.append(scalar.properties.generalCategory == .control ? " " : scalar)
            }
        }
        var result = String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if result.count > maxTitleLength {
            result = String(result.prefix(maxTitleLength)).trimmingCharacters(in: .whitespaces)
        }
        return result.isEmpty ? "Untitled" : result
    }
}
