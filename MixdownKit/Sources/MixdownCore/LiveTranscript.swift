import Foundation

/// The text recognized so far while recording, as lines: one speaker's words until they pause or
/// someone else speaks. Shown while recording and, once it ends, the note's transcript.
///
/// Each input is transcribed on its own, and their updates arrive out of step by a fraction of a
/// second. Lines are therefore kept in the order the words were spoken, not the order they
/// arrived in. Inputs can be added while recording, and an input can switch devices, each
/// recording with a clock of its own; updates say which audio their times count from.
public struct LiveTranscript: Sendable, Equatable {
    public struct Line: Sendable, Equatable, Identifiable {
        /// Stable while the line grows and as lines are inserted before it.
        public let id: Int
        /// Index of the input.
        let source: Int
        /// The input's label when several are recorded, else `nil`.
        public internal(set) var speaker: String?
        /// Seconds on the recording's timeline.
        public internal(set) var start: TimeInterval
        public internal(set) var end: TimeInterval
        public internal(set) var words: [String]

        public var text: String { words.joined(separator: " ") }
    }

    /// A pause at least this long starts a new line.
    static let pauseThreshold: TimeInterval = 2
    /// A line this long ends at the next sentence end, so a monologue doesn't become one block.
    static let sentenceBreakWordCount = 60
    /// A line this long ends regardless.
    static let maxWordCount = 150

    public private(set) var lines: [Line] = []
    /// Advances whenever `lines` changes; cheaper to watch than the lines themselves.
    public private(set) var revision = 0

    private struct Source: Sendable, Equatable {
        var speaker: String?
        /// Seconds from `referenceHostTime` to the input's first sample, once known. Segments are
        /// timed from there.
        var offset: TimeInterval?
        /// Index in `lines` of the input's latest line, which its next word may continue.
        var openLine: Int?
        /// The input's words for the note, split only by its own pauses and line length. Lines
        /// also split where another input speaks in between, which would cut crosstalk into
        /// fragments.
        var segments: [Segment] = []
        /// Whether the next word starts a segment, as after a device switch.
        var breaksSegment = false
    }

    private struct Segment: Sendable, Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var words: [String]
    }

    private var sources: [Source]
    /// Host time that the inputs' offsets are measured from: the first one reported.
    private var referenceHostTime: TimeInterval?
    private var nextLineID = 0

    /// - Parameter speakers: One label per input, in the order `apply` refers to them by index.
    ///   `nil` for an input whose lines shouldn't be labeled, such as the only one.
    public init(speakers: [String?]) {
        sources = speakers.map { Source(speaker: $0) }
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// Adds an unlabeled input, such as system audio turned on mid-recording. Its index follows
    /// the others'.
    public mutating func addSource() {
        sources.append(Source(speaker: nil))
    }

    /// Starts input `index`'s next word on a segment of its own, e.g. when it switches devices, so
    /// the note can name each device's words after it. Lines aren't affected.
    public mutating func breakSegment(ofSource index: Int) {
        guard sources.indices.contains(index) else { return }
        sources[index].breaksSegment = true
    }

    /// Relabels input `index`, including the lines it already has, e.g. once a second input
    /// makes labels necessary.
    public mutating func setSpeaker(_ speaker: String?, ofSource index: Int) {
        guard sources.indices.contains(index), sources[index].speaker != speaker else { return }
        sources[index].speaker = speaker
        for line in lines.indices where lines[line].source == index {
            lines[line].speaker = speaker
        }
        revision += 1
    }

    /// What input `index` said, as transcript segments timed in seconds from its first sample.
    public func segments(fromSource index: Int) -> [TranscriptSegment] {
        guard sources.indices.contains(index) else { return [] }
        let offset = sources[index].offset ?? 0
        return sources[index].segments.map { segment in
            TranscriptSegment(
                start: segment.start - offset,
                end: segment.end - offset,
                text: segment.words.joined(separator: " ")
            )
        }
    }

    /// Adds what input `index` recognized.
    /// - Parameter startHostTime: Host time of the first sample of the audio the update's times
    ///   count from, which lines the inputs up with each other; `nil` if unknown.
    public mutating func apply(_ update: LiveTranscriptUpdate, fromSource index: Int, startHostTime: TimeInterval?) {
        guard sources.indices.contains(index), !update.isEmpty else { return }
        let offset = offset(ofSource: index, startHostTime: startHostTime)
        revision += 1

        var words = update.words[...]
        if update.revisesLastWord, let open = sources[index].openLine, let word = words.first {
            lines[open].words[lines[open].words.count - 1] = word.text
            lines[open].end = max(lines[open].end, offset + word.end)
            let last = sources[index].segments.count - 1
            sources[index].segments[last].words[sources[index].segments[last].words.count - 1] = word.text
            sources[index].segments[last].end = max(sources[index].segments[last].end, offset + word.end)
            words = words.dropFirst()
        }
        for word in words {
            place(word, fromSource: index, offset: offset)
        }
    }

    /// Seconds from `referenceHostTime` to `startHostTime`. The first for an input is its offset.
    private mutating func offset(ofSource index: Int, startHostTime: TimeInterval?) -> TimeInterval {
        var offset: TimeInterval = 0
        if let startHostTime {
            let reference = referenceHostTime ?? startHostTime
            referenceHostTime = reference
            offset = startHostTime - reference
        }
        if sources[index].offset == nil { sources[index].offset = offset }
        return offset
    }

    private mutating func place(_ word: LiveWord, fromSource index: Int, offset: TimeInterval) {
        let start = offset + word.start
        let end = max(offset + word.end, start)
        if !sources[index].breaksSegment, let last = sources[index].segments.indices.last,
            start - sources[index].segments[last].end < Self.pauseThreshold,
            !Self.isComplete(sources[index].segments[last].words)
        {
            sources[index].segments[last].words.append(word.text)
            sources[index].segments[last].end = max(sources[index].segments[last].end, end)
        } else {
            sources[index].segments.append(Segment(start: start, end: end, words: [word.text]))
            sources[index].breaksSegment = false
        }

        if let open = sources[index].openLine, continues(open, at: start) {
            lines[open].words.append(word.text)
            lines[open].end = max(lines[open].end, end)
            return
        }

        // After every line that started earlier; usually at the end.
        let position = lines.lastIndex { $0.start <= start }.map { $0 + 1 } ?? 0
        let line = Line(
            id: nextLineID,
            source: index,
            speaker: sources[index].speaker,
            start: start,
            end: end,
            words: [word.text]
        )
        nextLineID += 1
        lines.insert(line, at: position)
        for other in sources.indices {
            if let open = sources[other].openLine, open >= position {
                sources[other].openLine = open + 1
            }
        }
        sources[index].openLine = position
    }

    /// Whether a word starting at `start` belongs on line `index` rather than a new one.
    private func continues(_ index: Int, at start: TimeInterval) -> Bool {
        let line = lines[index]
        guard start - line.end < Self.pauseThreshold, !Self.isComplete(line.words) else { return false }
        // Someone else started speaking in between. Lines are in start order, so the next one
        // is the only one to check.
        return !(lines.indices.contains(index + 1) && lines[index + 1].start <= start)
    }

    /// Whether a line of `words` is long enough to end here.
    private static func isComplete(_ words: [String]) -> Bool {
        guard words.count < maxWordCount else { return true }
        guard words.count >= sentenceBreakWordCount, let last = words.last?.last else { return false }
        return sentenceEnds.contains(last)
    }

    private static let sentenceEnds: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]
}
