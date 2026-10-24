import Foundation
import MixdownNotes
import Testing

struct NoteLookupTests {
    private let directory = URL(filePath: "/Users/me/Notes", directoryHint: .isDirectory)

    private func note(_ path: String, title: String, createdAt: TimeInterval) -> NoteDocument {
        let url = directory.appending(path: path, directoryHint: .notDirectory)
        return NoteDocument(url: url, contents: "# \(title)\n", fileDate: Date(timeIntervalSince1970: createdAt))
    }

    /// Newest first, as `NoteLibrary.loadNotes(in:cache:)` lists them.
    private var notes: [NoteDocument] {
        [
            note("Clients/Acme/2026-10-24 0930 Weekly Sync.md", title: "Weekly Sync", createdAt: 300),
            note("2026-10-23 1400 Standup.md", title: "Standup", createdAt: 200),
            note("2026-10-17 0930 Weekly Sync.md", title: "Weekly Sync", createdAt: 100),
        ]
    }

    private func find(_ reference: String) -> String? {
        NoteLibrary.note(for: reference, in: notes, directory: directory)?.url.lastPathComponent
    }

    @Test func findsNotesByPathInTheNotesFolder() {
        #expect(find("2026-10-23 1400 Standup.md") == "2026-10-23 1400 Standup.md")
        #expect(find("2026-10-23 1400 standup") == "2026-10-23 1400 Standup.md")
        #expect(find("Clients/Acme/2026-10-24 0930 Weekly Sync") == "2026-10-24 0930 Weekly Sync.md")
        #expect(find("./Clients/../2026-10-17 0930 Weekly Sync.md") == "2026-10-17 0930 Weekly Sync.md")
    }

    @Test func findsNotesByAbsolutePathOrFileURL() {
        #expect(find("/Users/me/Notes/2026-10-23 1400 Standup.md") == "2026-10-23 1400 Standup.md")
        #expect(find("file:///Users/me/Notes/2026-10-23%201400%20Standup.md") == "2026-10-23 1400 Standup.md")
    }

    @Test func findsTheNewestNoteWithATitle() {
        let note = NoteLibrary.note(for: "weekly sync", in: notes, directory: directory)
        #expect(note?.createdAt.timeIntervalSince1970 == 300)
        #expect(find(" Standup ") == "2026-10-23 1400 Standup.md")
    }

    @Test func findsTheNewestNoteForLatest() {
        #expect(find("latest") == "2026-10-24 0930 Weekly Sync.md")
        #expect(find("Latest") == "2026-10-24 0930 Weekly Sync.md")
        #expect(NoteLibrary.note(for: "latest", in: [], directory: directory) == nil)
    }

    @Test func findsNothingElse() {
        #expect(find("Retro") == nil)
        #expect(find("") == nil)
        // Outside the notes folder, even if it exists.
        #expect(find("/etc/hosts") == nil)
        #expect(find("../Other/2026-10-23 1400 Standup.md") == nil)
    }
}
