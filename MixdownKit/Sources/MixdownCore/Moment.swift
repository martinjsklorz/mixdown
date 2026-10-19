import Foundation

/// A point in a recording the user marked to come back to, e.g. with the Mark Moment shortcut,
/// with a few words on it if they wrote some.
public struct Moment: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Seconds from the start of the recording, not counting pauses, like the transcript's times.
    public var time: TimeInterval
    /// What the user wrote about it; empty if nothing.
    public var text: String

    public init(id: UUID = UUID(), time: TimeInterval, text: String = "") {
        self.id = id
        self.time = time
        self.text = text
    }
}

extension Transcript {
    /// What was being said at `time`: the last segment that started by then, if it hasn't been
    /// over for longer than `maxGap` seconds. A moment is usually marked just after what it's
    /// about was said.
    public func segment(at time: TimeInterval, maxGap: TimeInterval = 10) -> TranscriptSegment? {
        guard
            let segment = segments.last(where: {
                $0.start <= time && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }),
            time - segment.end <= maxGap
        else { return nil }
        return segment
    }
}
