import Foundation
import MixdownCore
import MixdownNotes

/// Writes notes into the notes folder wherever it is at the time. Checks the folder first with
/// `NotesFolderStore.refresh()`, so one renamed or moved while Mixdown was in the background is
/// found again rather than recreated, empty, where it was.
struct NotesFolderWriter: NoteWriting {
    let notesFolder: NotesFolderStore

    func write(_ note: Note) async throws -> URL {
        let directory = await MainActor.run {
            notesFolder.refresh()
            return notesFolder.directory
        }
        guard let directory else { throw NoteWritingError.noFolder }
        return try await MarkdownNoteWriter(directory: directory).write(note)
    }
}

extension NotesFolderStore {
    /// Writes notes into the folder; `nil` while there isn't one, so recording waits for it.
    var noteWriter: (any NoteWriting)? {
        directory.map { _ in NotesFolderWriter(notesFolder: self) }
    }
}
