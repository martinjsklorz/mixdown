import Foundation

/// What was said in the last few minutes of a recording still under way, summed up for someone
/// who drifted off. See `RecordingCoordinator.catchUp(onLast:with:)`.
public struct CatchUp: Sendable, Equatable {
    /// Seconds of the recording it covers, up to where it was asked for: as many as asked for,
    /// or fewer if the recording isn't that long yet.
    public let duration: TimeInterval
    /// A few short points, in the order they came up.
    public let points: [String]

    public init(duration: TimeInterval, points: [String]) {
        self.duration = duration
        self.points = points
    }
}

public enum CatchUpError: LocalizedError, Sendable, Equatable {
    case notRecording
    /// The recording isn't transcribed while it's recorded, so there's no text to catch up on.
    case noLiveText
    /// Nobody said anything in the time asked about, or nothing the summarizer made a point of.
    case nothingSaid

    public var errorDescription: String? {
        switch self {
        case .notRecording:
            "There's no recording to catch up on."
        case .noLiveText:
            "Catching up needs a speech model that shows the text as you speak. Choose one in "
                + "Settings → Transcription for your next recording."
        case .nothingSaid:
            "Nothing much was said in that time."
        }
    }
}
