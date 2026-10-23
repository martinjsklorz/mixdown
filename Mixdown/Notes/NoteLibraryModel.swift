import Foundation
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

    /// The notes read last time, so a reload only reads the files that changed.
    @ObservationIgnored private var cache = NoteLibrary.Cache()
    /// The folder the latest `reload(from:)` asked for.
    @ObservationIgnored private var directory: URL?
    /// Counts calls to `reload(from:)`, and the call the shown `notes` are as new as.
    @ObservationIgnored private var requested = 0
    @ObservationIgnored private var loaded = 0
    /// Reads the folder until `notes` catch up with `requested`. Only one runs at a time.
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// Reads the folder again and returns once `notes` show it as it was at the time of the call
    /// or later, so a note written just before can be selected. Calls made while a read is
    /// running share one more read after it.
    ///
    /// Without a `directory` (no notes folder, or it can't be reached) the list is empty.
    func reload(from directory: URL?) async {
        self.directory = directory
        requested += 1
        let task = loading ?? Task { await loadUntilCurrent() }
        loading = task
        await task.value
    }

    private func loadUntilCurrent() async {
        while loaded < requested {
            let target = requested
            let directory = self.directory
            let cache = self.cache
            let (result, newCache) = await Task.detached(priority: .userInitiated) {
                var cache = cache
                guard let directory else { return (Result<[NoteDocument], any Error>.success([]), cache) }
                return (Result { try NoteLibrary.loadNotes(in: directory, cache: &cache) }, cache)
            }.value
            self.cache = newCache
            // Asked again meanwhile: the next pass shows the newer state, without briefly
            // showing this one (e.g. a note just moved to the Trash).
            guard requested == target else { continue }

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
            loaded = target
        }
        loading = nil
    }

    /// Renames the note and its file, off the main thread. Returns the note's new URL.
    func rename(_ note: NoteDocument, to title: String) async throws -> URL {
        let url = note.url
        return try await Task.detached(priority: .userInitiated) {
            try NoteLibrary.rename(noteAt: url, to: title)
        }.value
    }

    /// Renames one of the note's speakers throughout it, off the main thread.
    func renameSpeaker(_ speaker: String, to name: String, in note: NoteDocument) async throws {
        let url = note.url
        try await Task.detached(priority: .userInitiated) {
            try NoteLibrary.renameSpeaker(speaker, to: name, inNoteAt: url)
        }.value
    }

    /// Pins or unpins the note, off the main thread.
    func setPinned(_ isPinned: Bool, _ note: NoteDocument) async throws {
        let url = note.url
        try await Task.detached(priority: .userInitiated) {
            try NoteLibrary.setPinned(isPinned, noteAt: url)
        }.value
    }

    /// Drops a note that was moved away from `notes` right away, ahead of the next reload.
    func didRemove(_ note: NoteDocument) {
        withAnimation(.snappy) { notes.removeAll { $0.id == note.id } }
    }
}
