import Foundation
import MixdownNotes
import Observation

/// The notes listed in the main window's sidebar, read from the notes folder off the main thread.
@MainActor @Observable
final class NoteLibraryModel {
    private(set) var notes: [NoteDocument] = []
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false

    /// Bumped per reload so a slow, older reload can't overwrite a newer result.
    @ObservationIgnored private var generation = 0

    /// Without a `directory` (no notes folder, or it can't be reached) the list is empty.
    func reload(from directory: URL?) async {
        generation += 1
        let current = generation
        guard let directory else {
            notes = []
            errorMessage = nil
            hasLoaded = true
            return
        }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try NoteLibrary.loadNotes(in: directory) }
        }.value
        guard current == generation else { return }

        switch result {
        case .success(let notes):
            self.notes = notes
            errorMessage = nil
        case .failure(let error):
            notes = []
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Renames the note and its file, off the main thread. Returns the note's new URL.
    func rename(_ note: NoteDocument, to title: String) async throws -> URL {
        let url = note.url
        return try await Task.detached(priority: .userInitiated) {
            try NoteLibrary.rename(noteAt: url, to: title)
        }.value
    }

    /// Drops a note that was moved away from `notes` right away, ahead of the next reload.
    func didRemove(_ note: NoteDocument) {
        notes.removeAll { $0.id == note.id }
    }
}
