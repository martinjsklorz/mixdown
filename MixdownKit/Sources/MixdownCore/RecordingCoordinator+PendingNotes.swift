import Foundation
import os

extension RecordingCoordinator {
    /// Writes `pendingNotes`, oldest first, updating `lastNoteURL` for each. Stops at the first that
    /// fails, returning its error, and tries again after `pendingNoteRetryInterval` if there's a
    /// `noteWriter`; without one, it waits for the next. Returns `nil` right away if a save is
    /// already under way; that one saves notes added meanwhile too.
    @discardableResult
    func savePendingNotes() async -> (any Error)? {
        guard !isSavingPendingNotes else { return nil }
        isSavingPendingNotes = true
        defer { isSavingPendingNotes = false }
        cancelPendingNoteRetry()

        while let note = pendingNotes.first {
            let generation = noteWriterGeneration
            do {
                guard let noteWriter else { throw NoteWritingError.noFolder }
                let url = try await noteWriter.write(note)
                pendingNotes.removeFirst()
                lastNoteURL = url
                logger.info("Wrote note to \(url.path(percentEncoded: false), privacy: .private)")
            } catch {
                // The folder changed while writing; try the new one.
                if generation != noteWriterGeneration { continue }
                let count = pendingNotes.count
                logger.error(
                    "Saving \(count) note(s) failed, keeping them: \(error.localizedDescription, privacy: .public)"
                )
                if noteWriter != nil { schedulePendingNoteRetry() }
                return error
            }
        }
        if let unsavedNoteMessage, phase == .failed(message: unsavedNoteMessage) {
            phase = .idle
        }
        unsavedNoteMessage = nil
        return nil
    }

    private func cancelPendingNoteRetry() {
        pendingNoteRetry?.cancel()
        pendingNoteRetry = nil
    }

    private func schedulePendingNoteRetry() {
        pendingNoteRetry = Task { [weak self, interval = pendingNoteRetryInterval] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self else { return }
            // So saving doesn't cancel the task doing it.
            pendingNoteRetry = nil
            await savePendingNotes()
        }
    }

    /// Removes and returns `pendingNotes`, for the coordinator replacing this one. Returns nothing
    /// while they're being saved, as they may already be written.
    public func takePendingNotes() -> [Note] {
        guard !isSavingPendingNotes else { return [] }
        cancelPendingNoteRetry()
        defer { pendingNotes = [] }
        return pendingNotes
    }
}
