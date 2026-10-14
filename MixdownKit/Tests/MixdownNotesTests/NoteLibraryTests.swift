import Foundation
import MixdownCore
import MixdownNotes
import Testing

struct NoteLibraryTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NoteLibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ contents: String, to name: String, in directory: URL) throws {
        try Data(contents.utf8).write(to: directory.appending(path: name, directoryHint: .notDirectory))
    }

    @Test func loadsMarkdownFilesNewestFirst() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = MarkdownNoteWriter(directory: directory)
        let older = NoteFixtures.note(title: "Older")
        var newer = NoteFixtures.note(title: "Newer")
        newer.createdAt += 3600
        _ = try await writer.write(older)
        _ = try await writer.write(newer)
        _ = try await writer.write(newer)
        try write("# Plain", to: "Plain.markdown", in: directory)
        try write("# Ignored", to: "notes.txt", in: directory)
        try write("# Hidden", to: ".hidden.md", in: directory)
        try FileManager.default.createDirectory(
            at: directory.appending(path: "Folder.md", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )

        let notes = try NoteLibrary.loadNotes(in: directory)

        // "Plain" has no `created`, so it's dated now by the file system and comes first.
        #expect(notes.map(\.title) == ["Plain", "Newer", "Newer", "Older"])
    }

    @Test func missingDirectoryHasNoNotes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NoteLibraryTests-missing-\(UUID().uuidString)", directoryHint: .isDirectory)

        #expect(try NoteLibrary.loadNotes(in: directory).isEmpty)
    }
}
