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
        switch device.kind {
        case .systemAudio:
            return Self.nonBlank(systemAudio) ?? Self.defaultSystemAudio
        case .microphone:
            let base = Self.nonBlank(microphone) ?? Self.defaultMicrophone
            let microphoneCount = devices.filter { $0.kind == .microphone }.count
            return microphoneCount > 1 ? "\(base) (\(device.name))" : base
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
    /// How far apart (in seconds) a microphone segment and system-audio speech may be and still
    /// count as the same moment when looking for echo.
    static let echoTimeTolerance: TimeInterval = 1.5
    /// Share of a microphone segment's words that must also appear in overlapping system audio
    /// for it to be dropped as echo.
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
                if let speaker = segment.speaker {
                    segment.speaker = "\(source.label) (\(speaker))"
                } else {
                    segment.speaker = source.label
                }
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

    /// Whether most of `segment`'s words were said in `reference` around the same time.
    static func isEcho(_ segment: TranscriptSegment, of reference: [TranscriptSegment]) -> Bool {
        let words = normalizedWords(segment.text)
        guard !words.isEmpty else { return false }

        let nearby = reference.filter {
            $0.start < segment.end + echoTimeTolerance && $0.end > segment.start - echoTimeTolerance
        }
        guard !nearby.isEmpty else { return false }

        var available: [Substring: Int] = [:]
        for word in nearby.flatMap({ normalizedWords($0.text) }) {
            available[word, default: 0] += 1
        }
        var matched = 0
        for word in words where available[word, default: 0] > 0 {
            available[word, default: 0] -= 1
            matched += 1
        }
        return Double(matched) / Double(words.count) >= echoWordShare
    }

    /// Lowercased words without punctuation.
    static func normalizedWords(_ text: String) -> [Substring] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }
    }
}
