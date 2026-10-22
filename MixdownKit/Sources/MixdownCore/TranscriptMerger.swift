import Foundation

/// Speaker names for multi-source recordings, by the kind of source the speech came from.
public struct SourceLabels: Sendable, Equatable {
    public static let defaultMicrophone = "Me"
    public static let defaultSystemAudio = "Others"

    /// Typically the user speaking into their own microphone.
    public var microphone: String
    /// Typically the other people on a call.
    public var systemAudio: String

    public init(microphone: String = Self.defaultMicrophone, systemAudio: String = Self.defaultSystemAudio) {
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    /// The label for `device`, falling back to the default when the configured one is blank.
    /// Microphones get their device name appended when several are recorded at once.
    public func label(for device: AudioInputDevice, among devices: [AudioInputDevice]) -> String {
        let base = label(for: device.kind)
        let microphoneCount = devices.filter { $0.kind == .microphone }.count
        return device.kind == .microphone && microphoneCount > 1 ? "\(base) (\(device.name))" : base
    }

    /// The label for every source of `kind`, falling back to the default when the configured one
    /// is blank.
    public func label(for kind: AudioSourceKind) -> String {
        switch kind {
        case .systemAudio: Self.nonBlank(systemAudio) ?? Self.defaultSystemAudio
        // An imported file is a note's only source, so it's never labeled.
        case .microphone, .file: Self.nonBlank(microphone) ?? Self.defaultMicrophone
        }
    }

    private static func nonBlank(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The transcript of one source in a multi-source recording, already shifted onto the shared
/// timeline.
public struct SourceTranscript: Sendable, Equatable {
    public var device: AudioInputDevice
    public var label: String
    public var transcript: Transcript

    public init(device: AudioInputDevice, label: String, transcript: Transcript) {
        self.device = device
        self.label = label
        self.transcript = transcript
    }
}

/// Combines per-source transcripts into one conversation.
public enum TranscriptMerger {
    /// Microphone segments shorter than this many words are never treated as echo: replies like
    /// "Yes." or "Sounds good." are too common to tell apart from what the others said. Text
    /// without spaces between words is weighed by characters, see `words(in:)`.
    static let echoMinimumWords = 4.0
    /// How far apart in time the two engines may place the same speech, in seconds.
    static let echoDrift = 1.0
    /// Share of a microphone segment's word pairs that must also appear, in the same order, in
    /// overlapping system audio for it to be dropped as echo.
    static let echoWordShare = 0.6

    /// Labels every segment with its source, drops microphone segments that merely repeat what
    /// the speakers played (no headphones), and interleaves the rest by start time.
    ///
    /// Speakers told apart by a diarizing engine keep their number within each source, e.g.
    /// "Me (Speaker 1)" and "Others (Speaker 2)": several people can share the microphone, and a
    /// call usually has several on the other end.
    public static func merge(_ sources: [SourceTranscript]) -> Transcript {
        let systemSegments =
            sources
            .filter { $0.device.kind == .systemAudio }
            .flatMap(\.transcript.segments)

        var merged: [(segment: TranscriptSegment, order: Int)] = []
        for (order, source) in sources.enumerated() {
            for var segment in source.transcript.segments {
                if source.device.kind == .microphone, isEcho(segment, of: systemSegments) { continue }
                segment.speaker = label(of: segment, in: source)
                merged.append((segment, order))
            }
        }
        // Stable for equal start times: sources keep their order.
        merged.sort { lhs, rhs in
            lhs.segment.start != rhs.segment.start ? lhs.segment.start < rhs.segment.start : lhs.order < rhs.order
        }
        return Transcript(
            segments: merged.map(\.segment),
            language: sources.lazy.compactMap(\.transcript.language).first
        )
    }

    /// The label `merge(_:)` gives `segment` of `source`: the source's, followed by the engine's
    /// speaker in parentheses if it has one.
    public static func label(of segment: TranscriptSegment, in source: SourceTranscript) -> String {
        segment.speaker.map { "\(source.label) (\($0))" } ?? source.label
    }

    /// Whether most of `segment`'s word pairs were said, in the same order, in `reference` at the
    /// same time.
    static func isEcho(_ segment: TranscriptSegment, of reference: [TranscriptSegment]) -> Bool {
        let spoken = words(in: segment.text)
        guard spoken.reduce(0, { $0 + $1.weight }) >= echoMinimumWords else { return false }
        let pairs = wordPairs(spoken)

        // Only the words the others said around the same time, so a short reply isn't compared
        // with a long stretch of them talking, and echo the engines cut up differently still
        // lines up.
        let from = segment.start - echoDrift
        let to = segment.end + echoDrift
        var available: [WordPair: Int] = [:]
        for other in reference where other.start <= to && other.end >= from {
            for pair in wordPairs(words(of: other, saidFrom: from, to: to)) {
                available[pair, default: 0] += 1
            }
        }
        guard !available.isEmpty else { return false }

        var matched = 0
        for pair in pairs where available[pair, default: 0] > 0 {
            available[pair, default: 0] -= 1
            matched += 1
        }
        return Double(matched) / Double(pairs.count) >= echoWordShare
    }

    /// The words of `segment` that were probably said between `from` and `to`. Engines only time
    /// whole segments, so this assumes an even pace through each one.
    private static func words(of segment: TranscriptSegment, saidFrom from: TimeInterval, to: TimeInterval) -> [Word] {
        let spoken = words(in: segment.text)
        let total = spoken.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return [] }
        let secondsPerWeight = max(segment.end - segment.start, 0) / total
        var said: [Word] = []
        var position = 0.0
        for word in spoken {
            let middle = segment.start + (position + word.weight / 2) * secondsPerWeight
            if middle >= from && middle <= to { said.append(word) }
            position += word.weight
        }
        return said
    }

    struct Word: Equatable {
        var text: Substring
        /// How much of a typical word this is: 1, or less for a single character of a script
        /// written without spaces.
        var weight: Double
    }

    private struct WordPair: Hashable {
        var first: Substring
        var second: Substring
    }

    /// Each word with the one after it, so matches have to keep the word order.
    private static func wordPairs(_ words: [Word]) -> [WordPair] {
        zip(words, words.dropFirst()).map { WordPair(first: $0.text, second: $1.text) }
    }

    /// Lowercased words without punctuation. Apostrophes are dropped rather than split on, so
    /// "it's" counts as one word.
    ///
    /// Chinese, Japanese, Thai and other scripts written without spaces can't be split into words
    /// without a dictionary, so each of their characters is a word of its own, weighted by how
    /// many of them a word typically takes.
    static func words(in text: String) -> [Word] {
        let text = text.lowercased().filter { $0 != "'" && $0 != "\u{2019}" }
        var words: [Word] = []
        var wordStart: String.Index?
        for index in text.indices {
            let character = text[index]
            let characterWeight = unspacedWeight(of: character)
            if characterWeight == nil, character.isLetter || character.isNumber {
                if wordStart == nil { wordStart = index }
                continue
            }
            if let start = wordStart {
                words.append(Word(text: text[start..<index], weight: 1))
                wordStart = nil
            }
            if let characterWeight {
                words.append(Word(text: text[index...index], weight: characterWeight))
            }
        }
        if let start = wordStart {
            words.append(Word(text: text[start...], weight: 1))
        }
        return words
    }

    /// The weight of one character of a script written without spaces, or `nil` for any other
    /// character.
    private static func unspacedWeight(of character: Character) -> Double? {
        guard let scalar = character.unicodeScalars.first else { return nil }
        switch scalar.value {
        // Chinese characters, also used in Japanese: a word is usually two.
        case 0x3005...0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF:
            return 1 / 2
        // Japanese kana, then Thai, Lao, Myanmar and Khmer: a word is usually three or more.
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,
            0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF:
            return 1 / 3
        default:
            return nil
        }
    }
}
