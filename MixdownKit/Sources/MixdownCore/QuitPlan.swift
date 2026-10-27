import Foundation

/// What to do when the user quits Mixdown, or the Mac logs out, restarts or shuts down, so no
/// recording or note is lost without asking. See `RecordingCoordinator.quitPlan(isSessionEnding:)`.
public enum QuitPlan: Equatable, Sendable {
    /// Stop the recording without making its note, as it's kept on disk to make it the next time
    /// Mixdown opens, then quit.
    case stopWithoutNoteThenQuit
    /// Stop the recording, which isn't all on disk, and quit once its note is saved.
    case stopThenQuitWhenDone
    /// Quit once the note being made is saved, as the recording isn't all on disk.
    case quitWhenDone
    /// Ask whether to stop the recording and quit once its note is saved, or quit now, which keeps
    /// it if `keepsRecording`, else loses it.
    case askWhileRecording(keepsRecording: Bool)
    /// Ask whether to quit once the note being made is saved, or now. Quitting now loses the import
    /// of `importing`, if it's a file being imported, and else the recording unless
    /// `keepsRecording`.
    case askWhileMakingNote(importing: String?, keepsRecording: Bool)
    /// Ask before losing notes that are waiting for the notes folder, then recordings only kept in
    /// memory.
    case askAboutLosingWork(pendingNotes: Int, recordingsInMemory: Int)
    case quitNow
}

extension RecordingCoordinator {
    /// What to do on quitting now. Logging out, restarting or shutting down, `isSessionEnding`,
    /// doesn't ask about recording or making a note, so it isn't held up: a recording kept on disk
    /// stops, to make its note the next time Mixdown opens, like one being made into a note already
    /// is. One that isn't stops, and Mixdown quits once its note is saved.
    public func quitPlan(isSessionEnding: Bool) -> QuitPlan {
        if isSessionEnding {
            if canStopRecording {
                return keepsRecordingWhenQuitting ? .stopWithoutNoteThenQuit : .stopThenQuitWhenDone
            }
            // An import is quit anyway, as it can be imported again.
            if isMakingNote, !keepsRecordingWhenQuitting, importingFileName == nil {
                return .quitWhenDone
            }
        } else if canStopRecording {
            return .askWhileRecording(keepsRecording: keepsRecordingWhenQuitting)
        } else if isMakingNote {
            return .askWhileMakingNote(importing: importingFileName, keepsRecording: keepsRecordingWhenQuitting)
        }
        let recordingsInMemory = unfinishedRecordings.filter { !$0.isOnDisk }.count
        guard !pendingNotes.isEmpty || recordingsInMemory > 0 else { return .quitNow }
        return .askAboutLosingWork(pendingNotes: pendingNotes.count, recordingsInMemory: recordingsInMemory)
    }
}
