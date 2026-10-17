import Foundation

/// Maps a transcription's work onto 0...1: the VAD pass first, then the pieces, weighted by
/// length. Pure; no model types involved.
///
/// Recognizers report nothing while they run, and a MOSS piece can be 10 minutes of audio, so
/// counting finished pieces alone leaves the bar at 0% for most of a short recording. While a
/// piece runs, its share fills on an estimate of how long it takes instead.
struct RecognitionProgress: Sendable {
    /// Share of the bar for the VAD pass, which takes seconds per hour of audio.
    static let detectionShare = 0.03
    /// How much of a running piece's share the estimate fills by the time the piece should be done.
    /// The rest fills ever more slowly, so a slower piece keeps moving without reaching its end.
    static let estimatedShare = 0.9

    /// Where each piece's share starts, plus 1 at the end.
    private let boundaries: [Double]

    init(pieceDurations: [TimeInterval]) {
        var weights = pieceDurations.map { $0.isFinite ? max($0, 0) : 0 }
        if weights.reduce(0, +) == 0 { weights = weights.map { _ in 1 } }
        let total = weights.reduce(0, +)
        var done = 0.0
        var boundaries = [Self.detectionShare]
        for weight in weights {
            done += weight
            boundaries.append(Self.detectionShare + (1 - Self.detectionShare) * done / total)
        }
        // Exactly 1, whatever the rounding.
        if weights.count > 0 { boundaries[boundaries.count - 1] = 1 }
        self.boundaries = boundaries
    }

    static func detection(_ fraction: Double) -> Double {
        detectionShare * clamped(fraction)
    }

    /// Progress once the first `count` pieces are done.
    func completed(_ count: Int) -> Double {
        boundaries[min(max(count, 0), boundaries.count - 1)]
    }

    /// Progress while piece `index` runs, `elapsed` seconds into an expected `expected`.
    func running(_ index: Int, elapsed: TimeInterval, expected: TimeInterval) -> Double {
        guard index >= 0, index + 1 < boundaries.count else { return completed(index) }
        let start = boundaries[index]
        return start + (boundaries[index + 1] - start) * Self.estimate(elapsed: elapsed, expected: expected)
    }

    /// Linear up to `estimatedShare` at `expected`, then approaching (but capped below) 1 exponentially.
    static func estimate(elapsed: TimeInterval, expected: TimeInterval) -> Double {
        guard elapsed > 0, expected > 0, elapsed.isFinite, expected.isFinite else { return 0 }
        if elapsed <= expected { return estimatedShare * elapsed / expected }
        return min(1 - (1 - estimatedShare) * exp(-(elapsed - expected) / expected), 0.99)
    }

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
