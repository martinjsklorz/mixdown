import Foundation
import MixdownCore
import MixdownNotes
import Observation
import SwiftUI

/// The notes in the notes folder, read off the main thread. One for the whole app (see
/// `AppEnvironment.library`), so the main window, Chat and Spotlight share one reading of the folder.
@MainActor @Observable
final class NoteLibraryModel {
    private(set) var notes: [NoteDocument] = []
    /// The folder `notes` were read from; `nil` without one, or if it couldn't be read.
    private(set) var folder: URL?
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false

    /// Reads the folder for `reload(from:)`.
    @ObservationIgnored private lazy var loader = NoteLibraryLoader { [weak self] result, directory in
        self?.show(result, from: directory)
    }
    /// Changes the notes' files one at a time, so one change can't undo another.
    @ObservationIgnored private let editor = NoteFileEditor()

    /// Reads the folder again and returns once `notes` show it as it was at the time of the call
    /// or later, so a note written just before can be selected. Calls made while a read is
    /// running share one more read after it.
    ///
    /// Without a `directory` (no notes folder, or it can't be reached) the list is empty.
    func reload(from directory: URL?) async {
        await loader.reload(from: directory)
    }

    private func show(_ result: Result<[NoteDocument], any Error>, from directory: URL?) {
        switch result {
        case .success(let notes):
            // Notes written or removed since slide in and out of the sidebar; the first
            // load just appears.
            withAnimation(hasLoaded ? .snappy : nil) { self.notes = notes }
            folder = directory
            errorMessage = nil
        case .failure(let error):
            notes = []
            folder = nil
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Renames the note and its file, off the main thread. Returns the note's new URL.
    func rename(_ note: NoteDocument, to title: String) async throws -> URL {
        try await editor.rename(noteAt: note.url, to: title)
    }

    /// Renames one of the note's speakers throughout it, off the main thread.
    func renameSpeaker(_ speaker: String, to name: String, in note: NoteDocument) async throws {
        try await editor.renameSpeaker(speaker, to: name, inNoteAt: note.url)
    }

    /// Pins or unpins the note, off the main thread.
    func setPinned(_ isPinned: Bool, _ note: NoteDocument) async throws {
        try await editor.setPinned(isPinned, noteAt: note.url)
    }

    /// Applies `vocabulary` to every note in `directory`, off the main thread, once the changes
    /// to notes asked for before are done.
    func applyVocabulary(
        _ vocabulary: Vocabulary,
        toNotesIn directory: URL
    ) async throws
        -> NoteLibrary.VocabularyChanges
    {
        try await editor.applyVocabulary(vocabulary, toNotesIn: directory)
    }

    /// Drops a note that was moved away from `notes` right away, ahead of the next reload.
    func didRemove(_ note: NoteDocument) {
        withAnimation(.snappy) { notes.removeAll { $0.id == note.id } }
    }
}
