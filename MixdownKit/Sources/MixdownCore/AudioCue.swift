import Foundation

/// A moment Mixdown marks with a short sound, so starting and stopping from the menu bar can be
/// heard without looking. Which sound, if any, is up to the app.
public enum AudioCue: String, CaseIterable, Identifiable, Sendable {
    case recordingStarted
    case recordingStopped
    case recordingPaused
    case recordingResumed
    case noteReady
    /// Recording couldn't start or stopped early, or the model or note couldn't be finished.
    case failed

    public var id: Self { self }

    /// The cue for the coordinator's phase changing from `old` to `new`, if any. Notes are cued
    /// separately, when `lastNoteURL` changes.
    ///
    /// A recording that ends in an error gets `failed` rather than `recordingStopped`, and so does
    /// a new error replacing an old one, e.g. a second failed start.
    public static func cue(
        from old: RecordingCoordinator.Phase,
        to new: RecordingCoordinator.Phase
    ) -> AudioCue? {
        guard old != new else { return nil }
        switch (old, new) {
        case (.recording, .recording), (.paused, .paused): return nil
        case (.recording, .paused): return .recordingPaused
        case (.paused, .recording): return .recordingResumed
        case (_, .recording): return .recordingStarted
        case (_, .failed): return .failed
        case (.recording, _), (.paused, _): return .recordingStopped
        default: return nil
        }
    }
}
