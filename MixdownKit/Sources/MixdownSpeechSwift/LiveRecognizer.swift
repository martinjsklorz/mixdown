@preconcurrency internal import AudioCommon
import Foundation
import MixdownCore
@preconcurrency internal import NemotronStreamingASR

/// Nemotron-3.5 ASR Streaming 0.6B (MLX, INT5), which transcribes while recording.
///
/// A cache-aware streaming model: it takes 320 ms of audio at a time and keeps its state between
/// calls, so text appears about half a second after it's spoken without reprocessing what came
/// before, and no audio needs keeping. One loaded model serves a session per input.
final class LiveRecognizer: @unchecked Sendable {
    /// `NemotronStreamingASRMLXModel.requiredBundleFiles` plus the language map it also needs.
    static let cachedModel = CachedModel(
        repositoryID: NemotronMLXVariant.int5.modelId,
        requiredFiles: ["config.json", "vocab.json", "languages.json"]
    )

    private let model: NemotronStreamingASRMLXModel

    private init(model: NemotronStreamingASRMLXModel) {
        self.model = model
    }

    static func load(cacheBase: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> LiveRecognizer {
        let model = try await cachedModel.load(base: cacheBase, progress: progress) { directory, offline, progress in
            try await NemotronStreamingASRMLXModel.fromPretrained(
                variant: .int5,
                cacheDir: directory,
                offlineMode: offline,
                progressHandler: { fraction, _ in progress(fraction) }
            )
        }
        return LiveRecognizer(model: model)
    }

    /// - Parameter languageCode: ISO 639-1, or `nil` to detect the language.
    func makeSession(languageCode: String?) throws -> LiveSessionState {
        let language = languageCode.map { Self.languageTags[$0] ?? $0 }
        return LiveSessionState(session: try model.createSession(language: language))
    }

    /// Nemotron resolves most bare language codes itself (`de` → `de-DE`); these it would
    /// otherwise detect automatically.
    private static let languageTags = ["ja": "ja-JP", "zh": "zh-CN"]
}

/// One input's Nemotron session and what it has reported so far. Only used on the
/// `SpeechSwiftEngine` actor, which runs every model call.
final class LiveSessionState: @unchecked Sendable {
    private let session: NemotronMLXStreamingSession
    private var diff = LiveWordDiff()

    init(session: NemotronMLXStreamingSession) {
        self.session = session
    }

    func push(_ samples: [Float]) throws -> LiveTranscriptUpdate {
        // Every partial carries the whole session's words, so only the latest one matters.
        guard let latest = try session.pushAudio(samples).last else { return LiveTranscriptUpdate() }
        return update(for: latest.words)
    }

    /// Transcribes the audio still buffered, padded to a whole chunk.
    func finish() throws -> LiveTranscriptUpdate {
        guard let latest = try session.finalize().last else { return LiveTranscriptUpdate() }
        return update(for: latest.words)
    }

    private func update(for words: [TimedWord]) -> LiveTranscriptUpdate {
        diff.update(words.map { LiveWord(text: $0.text, start: $0.startTime, end: $0.endTime) })
    }
}

/// Turns a session's cumulative words into what changed since the last call. The decoder only
/// ever appends tokens, so only the last word can still change, when it gains pieces or
/// punctuation.
struct LiveWordDiff {
    private var reportedWordCount = 0
    private var lastReportedWord: String?

    mutating func update(_ words: [LiveWord]) -> LiveTranscriptUpdate {
        defer {
            reportedWordCount = words.count
            lastReportedWord = words.last?.text
        }
        // Fewer words than reported isn't expected (re-segmenting, say), and the words already
        // reported can't be taken back. Carrying on from the shorter list keeps the words that
        // follow it.
        guard words.count >= reportedWordCount else { return LiveTranscriptUpdate() }
        var first = reportedWordCount
        var revisesLastWord = false
        if reportedWordCount > 0, words[reportedWordCount - 1].text != lastReportedWord {
            first -= 1
            revisesLastWord = true
        }
        return LiveTranscriptUpdate(revisesLastWord: revisesLastWord, words: Array(words[first...]))
    }
}

/// Hands each call to the engine, so sessions never run the model at the same time.
struct SpeechSwiftLiveSession: LiveTranscriptionSession {
    let engine: SpeechSwiftEngine
    let state: LiveSessionState

    func push(_ samples: [Float]) async throws -> LiveTranscriptUpdate {
        try await engine.push(samples, into: state)
    }

    func finish() async throws -> LiveTranscriptUpdate {
        try await engine.finish(state)
    }
}
