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

    func reload(from directory: URL) async {
        generation += 1
        let current = generation
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
}
