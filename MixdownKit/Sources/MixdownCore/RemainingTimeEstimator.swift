import Foundation

/// Estimates the time left for a 0...1 progress value from how fast it moved recently.
///
/// Uses the rate over a sliding window rather than since the start, so the estimate follows
/// changes in download speed. Gives no estimate until progress has moved for `minimumElapsed`.
public struct RemainingTimeEstimator: Sendable {
    private struct Sample: Sendable {
        let time: Date
        let progress: Double
    }

    public let window: TimeInterval
    public let minimumElapsed: TimeInterval
    private var samples: [Sample] = []

    public init(window: TimeInterval = 30, minimumElapsed: TimeInterval = 3) {
        self.window = window
        self.minimumElapsed = minimumElapsed
    }

    public mutating func add(progress: Double, at time: Date) {
        guard progress.isFinite else { return }
        // Progress going backwards means a new run (e.g. a retry): start over.
        if let last = samples.last, progress < last.progress || time < last.time {
            samples.removeAll()
        }
        samples.append(Sample(time: time, progress: min(max(progress, 0), 1)))
        // Keep one sample at or before the window start so the rate spans the whole window.
        while samples.count > 2, samples[1].time <= time.addingTimeInterval(-window) {
            samples.removeFirst()
        }
    }

    /// Seconds left at the latest sample, or `nil` while there isn't enough data.
    public var remaining: TimeInterval? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let elapsed = last.time.timeIntervalSince(first.time)
        let advanced = last.progress - first.progress
        guard elapsed >= minimumElapsed, advanced > 0 else { return nil }
        return (1 - last.progress) * elapsed / advanced
    }
}
