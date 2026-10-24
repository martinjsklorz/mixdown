import Foundation

/// A stretch of time in which one speaker talks. Speakers are numbered from 0 within one
/// recording; the numbers say nothing about who they are.
public struct SpeakerTurn: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var speaker: Int

    public init(start: TimeInterval, end: TimeInterval, speaker: Int) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// The seam between Mixdown and a model that tells speakers apart by their voices (diarization),
/// run on a whole input once its recording ends. It only says who spoke when, not who they are.
///
/// Implementations must run entirely on-device.
public protocol SpeakerDiarizer: Sendable {
    /// Whether the model is on disk, so `prepare` won't download anything. Read on the main actor;
    /// keep it cheap.
    var isDownloaded: Bool { get }

    /// Downloads the model if it isn't on disk. Honors task cancellation, which is how a download
    /// is cancelled.
    /// - Parameter progress: Reports 0...1. May be called from any thread.
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws

    /// Removes the model's files, so `isDownloaded` becomes false.
    func deleteModel() async throws

    /// Who spoke when in 16 kHz mono samples, in seconds from the first sample. Downloads the model
    /// first if need be. Turns of different speakers may overlap. Honors task cancellation.
    func diarize(_ samples: [Float]) async throws -> [SpeakerTurn]
}

/// Labels transcript segments with the speakers a `SpeakerDiarizer` found, splitting a segment
/// where the speaker changes within it.
public enum SpeakerAssignment {
    /// A turn this close to a word with no turn of its own still counts for it, in seconds.
    static let nearbyTurnDistance: TimeInterval = 1
    /// How many words a cut may move to land on a sentence end: placed by an even-pace estimate,
    /// or by the words' own times. Live engines time words a little late, and diarizers place turn
    /// changes a little off, so even timed words often land a word into the next speaker's turn.
    static let estimatedSnapWords = 3
    static let timedSnapWords = 2

    /// `segments`, labeled "Speaker 1", "Speaker 2", … in order of first appearance, and split where
    /// the speaker changes. Labels are left out if only one speaker talks, and segments as they are
    /// without any turns.
    ///
    /// - Parameters:
    ///   - words: Per segment, its words with their times, as a live engine recognizes them;
    ///     `nil` to place each segment's words at an even pace through it. Segments whose word count
    ///     doesn't match their text are placed at an even pace too.
    ///   - turns: On the same timeline as `segments`.
    public static func label(
        _ segments: [TranscriptSegment],
        words: [[LiveWord]]? = nil,
        turns: [SpeakerTurn]
    ) -> [TranscriptSegment] {
        let turns = turns.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !turns.isEmpty else { return segments }

        var pieces: [(segment: TranscriptSegment, speaker: Int?)] = []
        for (index, segment) in segments.enumerated() {
            let timed = words.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            pieces += split(segment, words: timed, turns: turns)
        }

        // Numbered by first appearance in the transcript.
        var numbers: [Int: Int] = [:]
        for piece in pieces.sorted(by: { $0.segment.start < $1.segment.start }) {
            if let speaker = piece.speaker, numbers[speaker] == nil { numbers[speaker] = numbers.count + 1 }
        }
        return pieces.map { piece in
            var segment = piece.segment
            segment.speaker = numbers.count > 1 ? piece.speaker.flatMap { numbers[$0] }.map { "Speaker \($0)" } : nil
            return segment
        }
    }

    private struct Token {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
    }

    /// `segment` as consecutive pieces of one speaker each.
    private static func split(
        _ segment: TranscriptSegment,
        words: [LiveWord]?,
        turns: [SpeakerTurn]
    ) -> [(segment: TranscriptSegment, speaker: Int?)] {
        let texts = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let tokens: [Token]
        let isTimed: Bool
        if let words, words.map(\.text) == texts {
            tokens = words.map { Token(text: $0.text, start: $0.start, end: $0.end) }
            isTimed = true
        } else {
            tokens = evenlyPaced(texts, from: segment.start, to: segment.end)
            isTimed = false
        }
        // Only turns near the segment can matter.
        let nearby = turns.filter {
            $0.end >= segment.start - nearbyTurnDistance && $0.start <= segment.end + nearbyTurnDistance
        }
        guard tokens.count > 1 else {
            return [(segment, speaker(from: segment.start, to: segment.end, among: nearby, all: turns))]
        }

        var speakers = tokens.map { speaker(from: $0.start, to: $0.end, among: nearby, all: turns) }
        fillGaps(&speakers)
        // Cuts are off by a word or more, and speakers mostly change between sentences.
        let runs = smoothed(
            Self.runs(of: speakers),
            tokens: tokens,
            snapWords: isTimed ? timedSnapWords : estimatedSnapWords
        )

        return runs.enumerated().map { index, run in
            let end = index + 1 < runs.count ? runs[index + 1].start : tokens.count
            let part = tokens[run.start..<end]
            var piece = segment
            piece.text = part.map(\.text).joined(separator: " ")
            // The first and last pieces keep the segment's own bounds.
            piece.start = index == 0 ? segment.start : tokens[run.start].start
            piece.end = index == runs.count - 1 ? segment.end : tokens[end - 1].end
            return (piece, run.speaker)
        }
    }

    /// Times for `words` spread across `start...end` by their length in characters.
    private static func evenlyPaced(_ words: [String], from start: TimeInterval, to end: TimeInterval) -> [Token] {
        let total = words.reduce(0) { $0 + $1.count + 1 }
        guard total > 0 else { return [] }
        let secondsPerCharacter = max(end - start, 0) / Double(total)
        var tokens: [Token] = []
        var position = start
        for word in words {
            let length = Double(word.count + 1) * secondsPerCharacter
            tokens.append(Token(text: word, start: position, end: position + length))
            position += length
        }
        return tokens
    }

    /// The speaker who talks most of `start..<end`; else the one whose turn is nearest, if within
    /// `nearbyTurnDistance`; else the nearest of `all`. `nil` only without turns.
    private static func speaker(
        from start: TimeInterval,
        to end: TimeInterval,
        among nearby: [SpeakerTurn],
        all: [SpeakerTurn]
    ) -> Int? {
        var overlaps: [Int: TimeInterval] = [:]
        for turn in nearby {
            let overlap = min(end, turn.end) - max(start, turn.start)
            if overlap > 0 { overlaps[turn.speaker, default: 0] += overlap }
        }
        // Ties go to the lower number, so the result doesn't depend on dictionary order.
        if let best = overlaps.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
            return best.key
        }
        let middle = (start + end) / 2
        return (nearby.isEmpty ? all : nearby).min { distance($0, to: middle) < distance($1, to: middle) }?.speaker
    }

    private static func distance(_ turn: SpeakerTurn, to time: TimeInterval) -> TimeInterval {
        time < turn.start ? turn.start - time : max(time - turn.end, 0)
    }

    /// Words without a speaker take the one before them, or else after.
    private static func fillGaps(_ speakers: inout [Int?]) {
        var last: Int?
        for index in speakers.indices {
            if speakers[index] == nil { speakers[index] = last } else { last = speakers[index] }
        }
        last = nil
        for index in speakers.indices.reversed() {
            if speakers[index] == nil { speakers[index] = last } else { last = speakers[index] }
        }
    }

    private struct Run {
        var speaker: Int?
        /// Index of the run's first word.
        var start: Int
    }

    private static func runs(of speakers: [Int?]) -> [Run] {
        var runs: [Run] = []
        for (index, speaker) in speakers.enumerated() where runs.isEmpty || runs[runs.count - 1].speaker != speaker {
            runs.append(Run(speaker: speaker, start: index))
        }
        return runs
    }

    /// `runs` with each cut moved to a sentence end at most `snapWords` away, which may leave a run
    /// with no words, and runs of a single word that isn't a sentence of its own given to the
    /// speaker before (or after) them.
    private static func smoothed(_ runs: [Run], tokens: [Token], snapWords: Int) -> [Run] {
        var starts = runs.map(\.start)
        for index in starts.indices.dropFirst() {
            let cut = starts[index]
            let previous = starts[index - 1]
            let next = index + 1 < starts.count ? starts[index + 1] : tokens.count
            let lower = max(previous, cut - snapWords, 1)
            let upper = min(next, cut + snapWords)
            guard lower <= upper else { continue }
            // A cut right before word `position` follows a sentence end if the word before it ends
            // one.
            let candidates = (lower...upper).filter { endsSentence(tokens[$0 - 1].text) }
            // Nearest first. Of two as near, one that keeps both runs, else the later one, as late
            // word times push cuts early.
            let best = candidates.min { lhs, rhs in
                let (lhsDistance, rhsDistance) = (abs(lhs - cut), abs(rhs - cut))
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                let (lhsEmpties, rhsEmpties) = (lhs == previous || lhs == next, rhs == previous || rhs == next)
                return lhsEmpties != rhsEmpties ? !lhsEmpties : lhs > rhs
            }
            if let best { starts[index] = best }
        }
        // Runs the cuts moved past are dropped.
        var moved: [Run] = []
        for (index, run) in runs.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : tokens.count
            if starts[index] < end { moved.append(Run(speaker: run.speaker, start: starts[index])) }
        }

        var kept: [Run] = []
        for (index, run) in moved.enumerated() {
            let end = index + 1 < moved.count ? moved[index + 1].start : tokens.count
            let isLoneWord = end - run.start == 1
            let isSentence =
                endsSentence(tokens[end - 1].text) && (run.start == 0 || endsSentence(tokens[run.start - 1].text))
            if isLoneWord, !isSentence, !kept.isEmpty { continue }
            if !kept.isEmpty, kept[kept.count - 1].speaker == run.speaker { continue }
            kept.append(run)
        }
        // A lone first word was kept for lack of a run before it; it goes to the one after.
        if kept.count > 1, kept[1].start == 1, !endsSentence(tokens[0].text) {
            kept[1].start = 0
            kept.removeFirst()
        }
        // The first run starts the segment, wherever the cuts moved.
        if !kept.isEmpty { kept[0].start = 0 }
        // Runs merged above may have left neighbors with the same speaker.
        var merged: [Run] = []
        for run in kept where merged.isEmpty || merged[merged.count - 1].speaker != run.speaker {
            merged.append(run)
        }
        return merged
    }

    private static let sentenceEnds: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]

    private static func endsSentence(_ word: String) -> Bool {
        // Past a closing quote or bracket.
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]»"))
        return trimmed.last.map { sentenceEnds.contains($0) } ?? false
    }
}
