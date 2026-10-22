import Foundation

/// How long the user and the others talked: the microphones for the user, system audio for the
/// others. Both are recorded on separate tracks, so who talked needs no guessing, only when.
public struct TalkTime: Sendable, Equatable {
    /// Seconds of speech on the microphones.
    public var microphone: TimeInterval
    /// Seconds of speech in the system audio.
    public var systemAudio: TimeInterval

    public init(microphone: TimeInterval = 0, systemAudio: TimeInterval = 0) {
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    public var total: TimeInterval { microphone + systemAudio }

    /// The microphones' part of the talking, 0...1. `nil` until anyone has talked.
    public var microphoneShare: Double? {
        total > 0 ? microphone / total : nil
    }

    /// `microphoneShare` and the rest as whole percentages that add up to 100.
    public var percentages: (microphone: Int, systemAudio: Int)? {
        guard let share = microphoneShare else { return nil }
        let microphone = Int((share * 100).rounded())
        return (microphone, 100 - microphone)
    }

    mutating func add(_ seconds: TimeInterval, from kind: AudioSourceKind) {
        switch kind {
        case .microphone: microphone += seconds
        case .systemAudio: systemAudio += seconds
        // Talk time is only measured while recording.
        case .file: break
        }
    }
}

/// How long each side talked in every minute of a recording.
public struct TalkTimeline: Sendable, Equatable {
    /// The length of each of the timeline's parts.
    public static let interval: TimeInterval = 60

    /// The speaker names of the two sides, as the transcript has them.
    public var microphoneLabel: String
    public var systemAudioLabel: String
    /// Seconds of speech in each minute, at most `interval`, from the microphones; the last minute
    /// may be shorter. As many as `systemAudio`.
    public var microphone: [TimeInterval]
    public var systemAudio: [TimeInterval]

    public init(
        microphoneLabel: String,
        systemAudioLabel: String,
        microphone: [TimeInterval],
        systemAudio: [TimeInterval]
    ) {
        let count = max(microphone.count, systemAudio.count)
        self.microphoneLabel = microphoneLabel
        self.systemAudioLabel = systemAudioLabel
        self.microphone = microphone + Array(repeating: 0, count: count - microphone.count)
        self.systemAudio = systemAudio + Array(repeating: 0, count: count - systemAudio.count)
    }

    /// The timeline of a recording `duration` seconds long, from when each side spoke. Spans are
    /// seconds on the recording's timeline; several sources of one kind, such as two microphones
    /// both hearing the user, count once.
    public init(
        labels: SourceLabels,
        microphone: [Range<TimeInterval>],
        systemAudio: [Range<TimeInterval>],
        duration: TimeInterval
    ) {
        let count = max(Int((duration / Self.interval).rounded(.up)), 1)
        self.init(
            microphoneLabel: labels.label(for: .microphone),
            systemAudioLabel: labels.label(for: .systemAudio),
            microphone: Self.perInterval(microphone, count: count),
            systemAudio: Self.perInterval(systemAudio, count: count)
        )
    }

    public var minuteCount: Int { microphone.count }

    public var total: TalkTime {
        TalkTime(microphone: microphone.reduce(0, +), systemAudio: systemAudio.reduce(0, +))
    }

    /// Seconds of `spans` in each of `count` intervals, overlaps counted once.
    private static func perInterval(_ spans: [Range<TimeInterval>], count: Int) -> [TimeInterval] {
        var seconds = [TimeInterval](repeating: 0, count: count)
        for span in merged(spans) {
            var start = max(span.lowerBound, 0)
            while start < span.upperBound {
                let index = Int(start / interval)
                guard index < count else { break }
                let end = min(span.upperBound, Double(index + 1) * interval)
                seconds[index] += end - start
                start = end
            }
        }
        return seconds
    }

    /// `spans` sorted, with overlapping and touching ones joined.
    private static func merged(_ spans: [Range<TimeInterval>]) -> [Range<TimeInterval>] {
        var merged: [Range<TimeInterval>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) where !span.isEmpty {
            if let last = merged.last, span.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}

/// Tells speech from silence and steady background noise in one source's audio, by loudness.
///
/// The audio is judged in short frames. A frame is speech if it's loud enough and well above the
/// noise floor, the quietest frame of the last few seconds: a room's hum or a fan stays at the
/// floor, while speech keeps dropping back to it between words and sentences. Until there's been
/// time for a pause, a quiet room is assumed, so speech right at the start counts. Short pauses
/// between speech count as talking too.
struct SpeechActivityDetector: Sendable {
    static let frameDuration: TimeInterval = 0.05
    private static let frameLength = Int(frameDuration * AudioChunk.sampleRate)
    /// How far back the noise floor is looked for, in frames (6 s).
    private static let floorWindow = 120
    /// How far above the noise floor speech is.
    private static let marginDecibels: Float = 10
    /// Quieter frames are never speech, however quiet the floor.
    private static let minimumDecibels: Float = -55
    /// The noise floor assumed at most for the first frames (2 s), before speech has paused.
    private static let startupFloorDecibels: Float = -50
    private static let startupFrames = 40
    /// Pauses of at most this many frames (300 ms) between speech count as speech.
    private static let maximumPauseFrames = 6

    /// Start and end of each stretch of speech so far, in seconds from the first sample, in order
    /// and apart.
    private(set) var spans: [Range<TimeInterval>] = []

    private var frame: [Float] = []
    private var frameIndex = 0
    /// Loudness of the last `floorWindow` frames, as a ring.
    private var recentDecibels: [Float] = []
    /// Frames since the last speech, while still within a pause that could count as speech.
    private var pauseFrames: Int?

    init() {
        frame.reserveCapacity(Self.frameLength)
    }

    /// Adds the samples that follow the previous call's and returns how many seconds of speech
    /// they made certain. A pause is only counted once speech follows it.
    mutating func add(_ samples: [Float]) -> TimeInterval {
        var speech: TimeInterval = 0
        for sample in samples {
            frame.append(sample)
            if frame.count == Self.frameLength {
                speech += closeFrame()
            }
        }
        return speech
    }

    /// Judges the frame filled so far and returns how many seconds of speech it added.
    private mutating func closeFrame() -> TimeInterval {
        let decibels = Self.decibels(of: frame)
        frame.removeAll(keepingCapacity: true)
        if recentDecibels.count < Self.floorWindow {
            recentDecibels.append(decibels)
        } else {
            recentDecibels[frameIndex % Self.floorWindow] = decibels
        }
        var floor = recentDecibels.min() ?? decibels
        if frameIndex < Self.startupFrames { floor = min(floor, Self.startupFloorDecibels) }
        let isSpeech = decibels >= Self.minimumDecibels && decibels >= floor + Self.marginDecibels
        defer { frameIndex += 1 }

        if isSpeech {
            // The pause before, if short enough, and this frame.
            let frames = 1 + (pauseFrames ?? 0)
            addSpan(endingAfter: frameIndex, frames: frames)
            pauseFrames = 0
            return Double(frames) * Self.frameDuration
        }
        if let paused = pauseFrames {
            pauseFrames = paused < Self.maximumPauseFrames ? paused + 1 : nil
        }
        return 0
    }

    private mutating func addSpan(endingAfter index: Int, frames: Int) {
        let start = Double(index + 1 - frames) * Self.frameDuration
        let end = Double(index + 1) * Self.frameDuration
        if let last = spans.last, last.upperBound >= start - Self.frameDuration / 2 {
            spans[spans.count - 1] = last.lowerBound..<end
        } else {
            spans.append(start..<end)
        }
    }

    /// RMS loudness in dBFS, at least -100 for digital silence.
    private static func decibels(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -100 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        let rms = (sum / Float(samples.count)).squareRoot()
        return max(20 * log10(max(rms, 1e-10)), -100)
    }
}
