import Foundation
import Observation
import os

/// Saves finished notes with a `NoteWriting`, and keeps those it can't save yet until it can, e.g.
/// because the notes folder is on a drive that was disconnected or asleep when the recording
/// finished. They're saved as soon as there's a `noteWriter` again, and retried every
/// `retryInterval` meanwhile. Only kept in memory, so they're lost if the app quits; a recording's
/// audio stays in the `RecordingStore` until its note is saved, though.
@MainActor
@Observable
final class NoteSaver {
    /// `nil` while there's no folder to save to. Setting it saves `pendingNotes`.
    var noteWriter: (any NoteWriting)? {
        didSet {
            generation &+= 1
            guard !pending.isEmpty else { return }
            Task { await saveAll() }
        }
    }
    /// Notes that couldn't be saved yet, oldest first.
    var pendingNotes: [Note] { pending.map(\.note) }
    /// True while `pendingNotes` are being written.
    var isSaving: Bool { saving != nil }
    /// Location of the most recently written note.
    private(set) var lastNoteURL: URL?
    /// How long to wait before trying to save `pendingNotes` again, while there's a `noteWriter`
    /// that failed to write them.
    var retryInterval: Duration = .seconds(30)
    /// Called once `saveAll()` has saved every pending note.
    @ObservationIgnored var didSaveAll: () -> Void = {}
    /// Called with each note once it's saved.
    @ObservationIgnored var didSave: (Note) -> Void = { _ in }

    /// Changes with every `noteWriter`, so a save that failed can tell it has a new one to try.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// `pendingNotes`, each with an ID for `save(_:)` to tell once its note is written.
    private var pending: [(id: UUID, note: Note)]
    /// The save under way, which `saveAll()` waits for rather than start another.
    private var saving: Task<(any Error)?, Never>?
    private let logger = Logger(subsystem: "app.mixdown", category: "notes")

    /// - Parameter pendingNotes: Notes still to be saved, e.g. from the saver this one replaces.
    ///   Saved right away.
    init(noteWriter: (any NoteWriting)?, pendingNotes: [Note] = []) {
        self.noteWriter = noteWriter
        self.pending = pendingNotes.map { (UUID(), $0) }
        if !pendingNotes.isEmpty {
            Task { await saveAll() }
        }
    }

    /// Saves `note` after any that are pending, or keeps it if it can't be saved yet. Returns why
    /// it couldn't, if it wasn't: the error of the note it's kept behind, or its own.
    func save(_ note: Note) async -> (any Error)? {
        let id = UUID()
        pending.append((id, note))
        // A save already under way saves the note too, unless it stops at one before it.
        while pending.contains(where: { $0.id == id }) {
            if let error = await saveAll() {
                return pending.contains { $0.id == id } ? error : nil
            }
        }
        return nil
    }

    /// Writes `pendingNotes`, oldest first, updating `lastNoteURL` for each. Stops at the first that
    /// fails, returning its error, and tries again after `retryInterval` if there's a `noteWriter`;
    /// without one, it waits for the next. If a save is already under way, waits for that one
    /// instead, which saves notes added meanwhile too, and returns its error.
    @discardableResult
    func saveAll() async -> (any Error)? {
        if let saving { return await saving.value }
        let task = Task { await writePendingNotes() }
        saving = task
        return await task.value
    }

    private func writePendingNotes() async -> (any Error)? {
        defer { saving = nil }
        cancelRetry()

        while let (id, note) = pending.first {
            let generation = generation
            do {
                guard let noteWriter else { throw NoteWritingError.noFolder }
                let url = try await noteWriter.write(note)
                pending.removeAll { $0.id == id }
                lastNoteURL = url
                didSave(note)
                logger.info("Wrote note to \(url.path(percentEncoded: false), privacy: .private)")
            } catch {
                // The folder changed while writing; try the new one.
                if generation != self.generation { continue }
                let count = pending.count
                logger.error(
                    "Saving \(count) note(s) failed, keeping them: \(error.localizedDescription, privacy: .public)"
                )
                if noteWriter != nil { scheduleRetry() }
                return error
            }
        }
        didSaveAll()
        return nil
    }

    /// Removes and returns `pendingNotes`, for the saver replacing this one. Returns nothing while
    /// they're being saved, as they may already be written.
    func takePendingNotes() -> [Note] {
        guard !isSaving else { return [] }
        cancelRetry()
        defer { pending = [] }
        return pendingNotes
    }

    private func cancelRetry() {
        retry?.cancel()
        retry = nil
    }

    private func scheduleRetry() {
        retry = Task { [weak self, retryInterval] in
            try? await Task.sleep(for: retryInterval)
            guard !Task.isCancelled, let self else { return }
            // So saving doesn't cancel the task doing it.
            retry = nil
            await saveAll()
        }
    }
}
