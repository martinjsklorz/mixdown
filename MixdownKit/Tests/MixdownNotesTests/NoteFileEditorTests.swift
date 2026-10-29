import Foundation
import MixdownCore
import Testing

@testable import MixdownNotes

struct NoteFileEditorTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NoteFileEditorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func loadNote(at url: URL) throws -> NoteDocument {
        NoteDocument(url: url, contents: try contents(of: url), fileDate: .distantPast)
    }

    private static let kubernetes = Vocabulary(entries: [.init(term: "Kubernetes", soundsLike: ["cooper netties"])])
    private static let friday = Vocabulary(entries: [.init(term: "Friday", soundsLike: ["fry day"])])

    @Test func changesAskedForAtOnceAllEndUpInTheNote() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await MarkdownNoteWriter(directory: directory).write(
            NoteFixtures.note(segments: [TranscriptSegment(start: 0, end: 4, text: "Cooper netties ships fry day.")])
        )
        let editor = NoteFileEditor()

        async let kubernetes = editor.applyVocabulary(Self.kubernetes, toNotesIn: directory)
        async let friday = editor.applyVocabulary(Self.friday, toNotesIn: directory)
        async let pinned: Void = editor.setPinned(true, noteAt: url)
        let changes = try await [kubernetes, friday]
        try await pinned

        let name = url.lastPathComponent
        #expect(changes.map { $0.correctedNotes.map(\.lastPathComponent) } == [[name], [name]])
        let note = try loadNote(at: url)
        #expect(note.isPinned)
        #expect(note.body.contains("Kubernetes ships Friday."))
    }

    @Test func rewriteKeepsAChangeMadeWhileItRan() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Note.md", directoryHint: .notDirectory)
        try "---\ntitle: \"Note\"\n---\nText".write(to: url, atomically: true, encoding: .utf8)
        var reads: [String] = []

        let isRewritten = try NoteLibrary.rewriteIfChanged(noteAt: url) { contents in
            reads.append(contents)
            // Another app saves the note between Mixdown reading and writing it.
            if reads.count == 1 {
                try? (contents + "\n\nAdded elsewhere.").write(to: url, atomically: true, encoding: .utf8)
            }
            return NoteDocument.pinned(contents, true)
        }

        #expect(isRewritten)
        #expect(reads.count == 2)
        #expect(try contents(of: url) == "---\ntitle: \"Note\"\npinned: true\n---\nText\n\nAdded elsewhere.")
    }

    @Test func rewriteGivesUpOnANoteThatKeepsChanging() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Note.md", directoryHint: .notDirectory)
        try "Text".write(to: url, atomically: true, encoding: .utf8)
        var reads = 0

        #expect(throws: NoteLibrary.KeptChangingError.self) {
            try NoteLibrary.rewriteIfChanged(noteAt: url) { contents in
                reads += 1
                try? (contents + " more").write(to: url, atomically: true, encoding: .utf8)
                return contents + " pinned"
            }
        }
        #expect(reads == NoteLibrary.maxRewriteAttempts)
        #expect(try !contents(of: url).contains("pinned"))
    }

    @Test func rewriteDoesNotBringBackANoteDeletedWhileItRan() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Note.md", directoryHint: .notDirectory)
        try "Text".write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try NoteLibrary.rewriteIfChanged(noteAt: url) { contents in
                try? FileManager.default.removeItem(at: url)
                return contents + " pinned"
            }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        // Nor leaves its new contents behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).isEmpty)
    }

    @Test func vocabularyCorrectsNotesInSubfoldersButNotHiddenOnes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = FileManager.default
        for folder in ["Clients/Acme", ".trash"] {
            try fileManager.createDirectory(at: directory.appending(path: folder), withIntermediateDirectories: true)
        }
        let inSubfolder = directory.appending(path: "Clients/Acme/Sync.md", directoryHint: .notDirectory)
        let inHidden = directory.appending(path: ".trash/Old.md", directoryHint: .notDirectory)
        for url in [inSubfolder, inHidden] {
            try "Cooper netties is ready.".write(to: url, atomically: true, encoding: .utf8)
        }

        let changes = try NoteLibrary.applyVocabulary(Self.kubernetes, toNotesIn: directory)

        #expect(changes.correctedNotes.map(\.lastPathComponent) == ["Sync.md"])
        #expect(try contents(of: inSubfolder) == "Kubernetes is ready.")
        #expect(try contents(of: inHidden) == "Cooper netties is ready.")
        #expect(try NoteLibrary.noteFiles(in: directory).map(\.folder) == ["Clients/Acme"])
    }

    @Test func vocabularyInAMissingFolderChangesNothing() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "Missing-\(UUID().uuidString)")
        #expect(try NoteLibrary.applyVocabulary(Self.kubernetes, toNotesIn: missing) == .init())
    }
}
