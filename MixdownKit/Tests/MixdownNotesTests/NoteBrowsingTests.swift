import Foundation
import MixdownNotes
import Testing

/// What the main window's note browser and folder watcher rely on: finding a note by its URL,
/// picking the next selection, and telling which folder events matter.
struct NoteBrowsingTests {
    private let directory = URL(filePath: "/Users/me/Notes", directoryHint: .isDirectory)

    private func note(_ path: String) -> NoteDocument {
        NoteDocument(
            url: directory.appending(path: path, directoryHint: .notDirectory),
            contents: "# Note\n",
            fileDate: .distantPast
        )
    }

    // MARK: note(at:in:)

    @Test func findsTheNoteAtAURLWhateverItsForm() {
        let notes = [note("2026-10-23 1400 Standup.md"), note("2026-10-17 0930 Weekly Sync.md")]
        let url = URL(filePath: "/Users/me/Notes/./2026-10-23 1400 STANDUP.md")
        #expect(NoteLibrary.note(at: url, in: notes)?.id == notes[0].id)
    }

    @Test func notesSharingANameAreToldApartByFolder() {
        let notes = [note("Clients/Acme/Weekly.md"), note("Weekly.md")]
        #expect(NoteLibrary.note(at: directory.appending(path: "Weekly.md"), in: notes)?.id == notes[1].id)
        #expect(
            NoteLibrary.note(at: directory.appending(path: "Clients/Acme/Weekly.md"), in: notes)?.id == notes[0].id
        )
        // Neither is at a third place, so it can't say which.
        #expect(NoteLibrary.note(at: URL(filePath: "/elsewhere/Weekly.md"), in: notes) == nil)
    }

    @Test func theOnlyNoteWithTheNameIsTakenEvenAtAnotherPath() {
        let notes = [note("Standup.md")]
        #expect(NoteLibrary.note(at: URL(filePath: "/Volumes/Notes/Standup.md"), in: notes)?.id == notes[0].id)
        #expect(NoteLibrary.note(at: URL(filePath: "/Volumes/Notes/Other.md"), in: notes) == nil)
    }

    // MARK: selectionAfterRemoving

    @Test func removingANoteSelectsTheOneBelowElseAbove() {
        let notes = [note("a.md"), note("b.md"), note("c.md")]
        #expect(NoteSection.selectionAfterRemoving(notes[0].id, from: notes) == notes[1].id)
        #expect(NoteSection.selectionAfterRemoving(notes[1].id, from: notes) == notes[2].id)
        #expect(NoteSection.selectionAfterRemoving(notes[2].id, from: notes) == notes[1].id)
        #expect(NoteSection.selectionAfterRemoving(notes[0].id, from: [notes[0]]) == nil)
        #expect(NoteSection.selectionAfterRemoving(note("gone.md").id, from: notes) == nil)
    }

    // MARK: change(from:in:)

    private func change(_ events: NoteLibrary.FolderEvent...) -> NoteLibrary.FolderChange? {
        NoteLibrary.change(from: events, in: directory)
    }

    @Test func noteAndFolderEventsMeanTheNotesChanged() {
        #expect(change(.init(path: "/Users/me/Notes/Standup.md")) == .notes)
        #expect(change(.init(path: "/Users/me/Notes/Clients", isDirectory: true)) == .notes)
    }

    @Test func eventsThatCantChangeNotesAreIgnored() {
        #expect(change(.init(path: "/Users/me/Notes/.DS_Store")) == nil)
        #expect(change(.init(path: "/Users/me/Notes/.obsidian/workspace.json")) == nil)
        #expect(change(.init(path: "/Users/me/Notes/photo.png")) == nil)
        #expect(change() == nil)
    }

    @Test func droppedEventsMeanReadingAgain() {
        #expect(change(.init(path: "/Users/me/Notes/.DS_Store", mustRescan: true)) == .notes)
    }

    @Test func aMovedRootCountsOverTheRest() {
        #expect(
            change(
                .init(path: "/Users/me/Notes/Standup.md"),
                .init(path: "/Users/me/Notes", isDirectory: true, rootChanged: true)
            ) == .rootChanged
        )
    }
}
