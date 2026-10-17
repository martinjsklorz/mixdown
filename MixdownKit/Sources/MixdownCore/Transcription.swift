import Foundation

/// A timed span of recognized speech.
public struct TranscriptSegment: Sendable, Codable, Equatable {
    /// Seconds from the start of the recording.
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// Speaker label such as `"Speaker 1"`, for engines that diarize. `nil` otherwise.
    public var speaker: String?

    public init(start: TimeInterval, end: TimeInterval, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

public struct Transcript: Sendable, Codable, Equatable {
    public var segments: [TranscriptSegment]
    /// ISO 639-1 code of the detected or requested language, if known.
    public var language: String?

    public init(segments: [TranscriptSegment], language: String? = nil) {
        self.segments = segments
        self.language = language
    }

    public var text: String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public var isEmpty: Bool { text.isEmpty }

    /// Distinct speaker labels in order of first appearance. Empty for engines that don't diarize.
    public var speakers: [String] {
        var seen = Set<String>()
        return segments.compactMap(\.speaker).filter { seen.insert($0).inserted }
    }
}

public struct TranscriptionOptions: Sendable, Equatable {
    /// ISO 639-1 language code, or `nil` to auto-detect.
    public var language: String?
    /// Translate the speech to English instead of transcribing it verbatim.
    public var translateToEnglish: Bool

    public init(language: String? = nil, translateToEnglish: Bool = false) {
        self.language = language
        self.translateToEnglish = translateToEnglish
    }
}

/// Identifies an engine for UI and note metadata.
public struct TranscriptionEngineInfo: Sendable, Equatable {
    /// Stable identifier, e.g. `"speech-swift"`.
    public let id: String
    /// Human-readable name, e.g. `"Qwen3-ASR 0.6B"`.
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// The seam between Mixdown and a speech-to-text backend.
///
/// Implementations must run entirely on-device. The rest of the app only ever talks to this
/// protocol, so swapping the speech model for another means adding a new conforming type and
/// changing a single line where the engine is constructed.
public protocol TranscriptionEngine: Sendable {
    var info: TranscriptionEngineInfo { get }

    /// Whether the model is on disk, so `prepare` won't download anything. Recording is only
    /// offered once this is true. Read on the main actor; keep it cheap.
    var isDownloaded: Bool { get }

    /// Downloads (if needed) and loads the model. Safe to call repeatedly; later calls are no-ops.
    /// Honors task cancellation, which is how a download is cancelled.
    /// - Parameter progress: Reports 0...1 while preparing. May be called from any thread.
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws

    /// Unloads the model and removes its files from disk, so `isDownloaded` becomes false and the
    /// next `prepare` downloads it again. Only called while nothing is preparing or transcribing.
    func deleteModel() async throws

    /// Called as a recording starts. An engine that frees its model when idle should load it now
    /// and keep it until the matching `recordingDidFinish()`, so stopping doesn't wait on a load.
    /// Returns right away; any loading happens in the background.
    func recordingWillStart()

    /// Balances `recordingWillStart()` once the recording has been transcribed, discarded or failed.
    func recordingDidFinish()

    /// Called with `TranscriptionOptions.language` before the first `isDownloaded`, and whenever it
    /// changes. For an engine with a model per language; `isDownloaded`, `prepare` and `deleteModel`
    /// then refer to this language's.
    func languageDidChange(to language: String?)

    /// Brings `isDownloaded` up to date, for an engine that can only check asynchronously. Until it
    /// has, such an engine reports `false`.
    func refreshDownloadStatus() async

    /// Whether recordings are transcribed while they're recorded, by `makeLiveSession`, rather than
    /// afterwards by `transcribe`. Live engines get no audio kept, however long the recording.
    var transcribesLive: Bool { get }

    /// Transcribes 16 kHz mono Float32 samples (see `AudioChunk.sampleRate`).
    /// Calls `prepare` implicitly if it hasn't completed yet. Honors task cancellation.
    /// Only called when `transcribesLive` is false.
    /// - Parameter progress: Reports 0...1 as the work gets done, never moving backwards. An engine
    ///   that can't tell may never call it. May be called from any thread.
    func transcribe(
        _ samples: [Float],
        options: TranscriptionOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript

    /// Starts transcribing one input as it's recorded. Calls `prepare` implicitly if it hasn't
    /// completed yet. Only called when `transcribesLive` is true.
    func makeLiveSession(options: TranscriptionOptions) async throws -> any LiveTranscriptionSession
}

/// A recognized word in a live transcript.
public struct LiveWord: Sendable, Equatable {
    public var text: String
    /// Seconds from the session's first sample.
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// What a live session recognized since its previous update.
public struct LiveTranscriptUpdate: Sendable, Equatable {
    /// Whether `words.first` replaces the previous update's last word, which the recognizer was
    /// still adding to (e.g. "transcri" became "transcription.").
    public var revisesLastWord: Bool
    /// New words in spoken order.
    public var words: [LiveWord]

    public init(revisesLastWord: Bool = false, words: [LiveWord] = []) {
        self.revisesLastWord = revisesLastWord
        self.words = words
    }

    public var isEmpty: Bool { words.isEmpty }
}

/// Transcribes one input while it's being recorded. Calls are made one at a time, in order.
public protocol LiveTranscriptionSession: Sendable {
    /// Feeds the samples that follow the previous call's (16 kHz mono), starting with the input's
    /// first sample, and returns what was recognized.
    func push(_ samples: [Float]) async throws -> LiveTranscriptUpdate

    /// Transcribes whatever audio the session still holds once the input has ended. Called once,
    /// after the last `push`.
    func finish() async throws -> LiveTranscriptUpdate
}

extension TranscriptionEngine {
    public func recordingWillStart() {}
    public func recordingDidFinish() {}
    public func languageDidChange(to language: String?) {}
    public func refreshDownloadStatus() async {}

    public var transcribesLive: Bool { false }

    public func makeLiveSession(options: TranscriptionOptions) async throws -> any LiveTranscriptionSession {
        throw TranscriptionError.failed("\(info.displayName) transcribes once the recording ends")
    }
}

public enum TranscriptionError: LocalizedError, Sendable {
    case modelUnavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason): "The transcription model couldn't be loaded: \(reason)"
        case .failed(let reason): "Transcription failed: \(reason)"
        }
    }
}
