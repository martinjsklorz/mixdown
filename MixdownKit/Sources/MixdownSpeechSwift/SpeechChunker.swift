import Foundation

/// A span of the recording, in seconds from its start.
struct TimeSpan: Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval

    var duration: TimeInterval { end - start }
}

/// One recognizer call's worth of audio.
struct SpeechPiece: Equatable, Sendable {
    /// Speech bounds from the VAD; used as the timestamps of untimed recognizer output.
    var speech: TimeSpan
    /// Audio handed to the recognizer: `speech` plus padding taken only from surrounding silence.
    var window: TimeSpan
}

/// Turns VAD speech regions into recognizer-sized pieces. Pure; no model types involved.
enum SpeechChunker {
    struct Configuration: Equatable, Sendable {
        /// Upper bound for `SpeechPiece.window.duration`, padding included.
        var maxWindowDuration: TimeInterval
        /// Neighbouring regions closer than this are transcribed together (more context, fewer calls).
        var maxMergeGap: TimeInterval
        /// Silence kept around speech so onsets and word endings aren't clipped.
        var padding: TimeInterval
        /// A region that is too long is cut at its quietest frame in
        /// `[minSplitFraction * budget, budget]` after the piece start.
        var minSplitFraction: Double = 0.5
    }

    static func pieces(
        regions: [TimeSpan],
        probabilities: [Float],
        frameDuration: TimeInterval,
        audioDuration: TimeInterval,
        configuration: Configuration
    ) -> [SpeechPiece] {
        let padding = max(0, configuration.padding)
        // Speech budget per piece, leaving room for padding on both sides. Never zero, so splitting terminates.
        let budget = max(configuration.maxWindowDuration - 2 * padding, 1)
        let splitFraction = min(max(configuration.minSplitFraction, 0.1), 1)

        let sanitized = regions
            .map { TimeSpan(start: max(0, $0.start), end: min(audioDuration, $0.end)) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }

        let split = sanitized.flatMap {
            Self.split(
                $0,
                budget: budget,
                splitFraction: splitFraction,
                probabilities: probabilities,
                frameDuration: frameDuration
            )
        }
        let merged = merge(split, maxGap: configuration.maxMergeGap, budget: budget)
        return pad(merged, padding: padding, audioDuration: audioDuration)
    }

    private static func split(
        _ region: TimeSpan,
        budget: TimeInterval,
        splitFraction: Double,
        probabilities: [Float],
        frameDuration: TimeInterval
    ) -> [TimeSpan] {
        var result: [TimeSpan] = []
        var start = region.start
        while region.end - start > budget {
            let earliest = start + budget * splitFraction
            let latest = start + budget
            let cut =
                quietestPoint(
                    from: earliest,
                    to: latest,
                    probabilities: probabilities,
                    frameDuration: frameDuration
                ) ?? latest
            result.append(TimeSpan(start: start, end: cut))
            start = cut
        }
        result.append(TimeSpan(start: start, end: region.end))
        return result
    }

    /// Frames on each side averaged when looking for a cut: ±3 Silero frames ≈ 0.2 s.
    static let smoothingRadius = 3

    /// Centre of the VAD frame whose centre lies in `[from, to]` and whose neighbourhood
    /// (`smoothingRadius` frames each side) is quietest on average. Ties go to the quieter frame
    /// itself, then to the later one.
    ///
    /// Averaging makes the cut land in a pause between words. The single quietest frame is often
    /// a stop consonant or a breath inside a word, and a cut there splits the word across pieces.
    private static func quietestPoint(
        from: TimeInterval,
        to: TimeInterval,
        probabilities: [Float],
        frameDuration: TimeInterval
    ) -> TimeInterval? {
        guard frameDuration > 0, !probabilities.isEmpty else { return nil }
        let first = max(0, Int((from / frameDuration - 0.5).rounded(.up)))
        let last = min(probabilities.count - 1, Int((to / frameDuration - 0.5).rounded(.down)))
        guard first <= last else { return nil }
        // Neighbours outside the region are used too: silence just past it still marks a pause.
        let lower = max(0, first - smoothingRadius)
        let upper = min(probabilities.count - 1, last + smoothingRadius)
        var sums = [Double](repeating: 0, count: upper - lower + 2)
        for index in lower...upper {
            sums[index - lower + 1] = sums[index - lower] + Double(probabilities[index])
        }
        func average(around index: Int) -> Double {
            let start = max(lower, index - smoothingRadius)
            let end = min(upper, index + smoothingRadius)
            return (sums[end - lower + 1] - sums[start - lower]) / Double(end - start + 1)
        }
        var best = first
        var bestAverage = average(around: first)
        for index in first...last {
            let value = average(around: index)
            let isTie = abs(value - bestAverage) < 1e-9
            if (isTie && probabilities[index] <= probabilities[best]) || (!isTie && value < bestAverage) {
                best = index
                bestAverage = value
            }
        }
        return (Double(best) + 0.5) * frameDuration
    }

    private static func merge(_ spans: [TimeSpan], maxGap: TimeInterval, budget: TimeInterval) -> [TimeSpan] {
        var merged: [TimeSpan] = []
        for span in spans {
            if let last = merged.last, span.start - last.end <= maxGap, span.end - last.start <= budget {
                merged[merged.count - 1].end = span.end
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// Pads into silence only: never past the midpoint of the gap to a neighbour, so windows don't overlap
    /// and pieces produced by a hard split (no gap) get no padding at the cut.
    private static func pad(_ spans: [TimeSpan], padding: TimeInterval, audioDuration: TimeInterval) -> [SpeechPiece] {
        spans.indices.map { index in
            let span = spans[index]
            let lower = index > 0 ? (spans[index - 1].end + span.start) / 2 : 0
            let upper = index + 1 < spans.count ? (span.end + spans[index + 1].start) / 2 : audioDuration
            let window = TimeSpan(
                start: max(span.start - padding, min(lower, span.start)),
                end: min(span.end + padding, max(upper, span.end))
            )
            return SpeechPiece(speech: span, window: window)
        }
    }
}
