import Foundation
import MixdownCore
import Synchronization
import os

/// On-device transcription with [speech-swift](https://github.com/soniqo/speech-swift) on MLX.
///
/// Silero VAD finds the speech; each `SpeechSwiftModel` decides how to cut it and how to turn a piece
/// into timed segments (see `SpeechRecognizer`). Transcriptions run one at a time.
///
/// The live model, Nemotron streaming ASR, instead transcribes each input while it's recorded
/// (see `LiveRecognizer`). Its calls run on this actor too, one at a time.
///
/// To use a different engine, add a module with a type conforming to `TranscriptionEngine` and construct
/// it in `AppEnvironment.makeCoordinator` instead of this one. Nothing else refers to speech-swift.
public actor SpeechSwiftEngine: TranscriptionEngine {
    private enum LoadedModels: Sendable {
        case offline(detector: VoiceActivityDetector, recognizer: any SpeechRecognizer)
        case live(LiveRecognizer)
    }

    public nonisolated let info: TranscriptionEngineInfo
    public nonisolated var transcribesLive: Bool { model.isLive }

    private nonisolated let model: SpeechSwiftModel
    private nonisolated let modelDirectory: URL?
    private var models: LoadedModels?
    private var loading: (task: Task<LoadedModels, any Error>, progress: ProgressRelay)?
    private var lastTranscription: Task<Void, Never>?
    private var hasLoggedTranslationNotice = false

    /// - Parameters:
    ///   - modelDirectory: Where weights are cached. Defaults to `Application Support/Mixdown/Models`
    ///     (inside the container when sandboxed).
    public init(model: SpeechSwiftModel = .default, modelDirectory: URL? = nil) {
        self.model = model
        self.modelDirectory = modelDirectory
        self.info = TranscriptionEngineInfo(id: "speech-swift", displayName: model.displayName)
    }

    /// Loads the model (and for offline models the VAD), downloading them on first use. Concurrent
    /// calls share one load; a failed load is retried by the next call. Throws
    /// `TranscriptionError.modelUnavailable`.
    ///
    /// Cancelling the calling task stops the download (for every caller sharing it) and throws
    /// `CancellationError`. Files already on disk are kept, so the next call resumes from them.
    public func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        _ = try await loadedModels(progress: progress)
    }

    /// Transcribes a whole recording of 16 kHz mono samples. Segments follow the VAD's speech regions
    /// (or the model's own timestamps for MOSS). `translateToEnglish` is not supported and ignored.
    /// Throws for the live model, which transcribes while recording instead.
    public func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> Transcript {
        let language = Self.languageCode(options.language)
        guard !samples.isEmpty else { return Transcript(segments: [], language: language) }
        return try await oneAtATime {
            try await self.performTranscription(samples, options: options, language: language)
        }
    }

    /// A session for one input of a recording; see `LiveRecognizer`. Loads the model if it isn't
    /// yet. Throws `TranscriptionError` for offline models or if the session can't start.
    public func makeLiveSession(options: TranscriptionOptions) async throws -> any LiveTranscriptionSession {
        guard case .live(let recognizer) = try await loadedModels(progress: nil) else {
            throw TranscriptionError.failed("\(model.displayName) transcribes once the recording ends")
        }
        do {
            let state = try recognizer.makeSession(languageCode: Self.languageCode(options.language))
            return SpeechSwiftLiveSession(engine: self, state: state)
        } catch {
            throw TranscriptionError.failed(error.localizedDescription)
        }
    }

    // A live session's calls. Synchronous, so no other model call on this actor runs meanwhile.

    func push(_ samples: [Float], into state: LiveSessionState) throws -> LiveTranscriptUpdate {
        do {
            return try state.push(samples)
        } catch {
            throw TranscriptionError.failed(error.localizedDescription)
        }
    }

    func finish(_ state: LiveSessionState) throws -> LiveTranscriptUpdate {
        do {
            return try state.finish()
        } catch {
            throw TranscriptionError.failed(error.localizedDescription)
        }
    }

    public nonisolated var isDownloaded: Bool {
        Self.isDownloaded(model, modelDirectory: modelDirectory)
    }

    /// Whether `model` (and for offline models the VAD) is already on disk, so `prepare` won't
    /// download anything. Checks files only; it doesn't validate them.
    public static func isDownloaded(_ model: SpeechSwiftModel, modelDirectory: URL? = nil) -> Bool {
        guard let base = try? modelDirectory ?? defaultModelDirectory(),
            let modelCacheDirectory = try? ModelCache.directory(for: model.repositoryID, base: base)
        else { return false }
        guard let recognizerType = model.recognizerType else {
            return LiveRecognizer.cacheLooksComplete(in: modelCacheDirectory)
        }
        guard let detectorDirectory = try? ModelCache.directory(for: VoiceActivityDetector.repositoryID, base: base)
        else { return false }
        return VoiceActivityDetector.cacheLooksComplete(in: detectorDirectory)
            && recognizerType.cacheLooksComplete(in: modelCacheDirectory)
    }

    /// Removes the ASR model's files and drops the loaded instance. The VAD (~2 MB) is kept, since
    /// every offline model shares it.
    public func deleteModel() async throws {
        loading?.task.cancel()
        loading = nil
        models = nil
        let base = try modelDirectory ?? Self.defaultModelDirectory()
        let directory = try ModelCache.directory(for: model.repositoryID, base: base)
        try FileManager.default.removeItem(at: directory)
        transcriptionLogger.info("Deleted \(self.model.displayName, privacy: .public)")
    }

    // MARK: - Loading

    private func loadedModels(progress: (@Sendable (Double) -> Void)?) async throws -> LoadedModels {
        if let models {
            progress?(1)
            return models
        }

        let loading = self.loading ?? startLoading()
        if let progress { loading.progress.add(progress) }
        let task = loading.task
        do {
            let loaded = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            // A load that finished despite being cancelled is still good.
            if models == nil { models = loaded }
            if self.loading?.task == task { self.loading = nil }
            return loaded
        } catch {
            // Cleared so the next call retries.
            if self.loading?.task == task { self.loading = nil }
            try Task.checkCancellation()
            // Another caller cancelled the load this one joined; start over rather than fail.
            if task.isCancelled {
                return try await loadedModels(progress: progress)
            }
            throw Self.unavailable(error)
        }
    }

    private func startLoading() -> (task: Task<LoadedModels, any Error>, progress: ProgressRelay) {
        let relay = ProgressRelay()
        let model = self.model
        let modelDirectory = self.modelDirectory
        let task = Task {
            do {
                let loaded = try await Self.load(model, modelDirectory: modelDirectory, progress: relay)
                transcriptionLogger.info("\(model.displayName, privacy: .public) ready")
                return loaded
            } catch {
                if Task.isCancelled {
                    transcriptionLogger.info("Loading \(model.displayName, privacy: .public) cancelled")
                } else {
                    transcriptionLogger.error(
                        "Loading \(model.displayName, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                    )
                }
                throw error
            }
        }
        loading = (task, relay)
        return (task, relay)
    }

    private static func load(
        _ model: SpeechSwiftModel,
        modelDirectory: URL?,
        progress: ProgressRelay
    ) async throws -> LoadedModels {
        let base = try modelDirectory ?? defaultModelDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let recognizerType = model.recognizerType else {
            let recognizer = try await LiveRecognizer.load(cacheBase: base) { progress.report($0) }
            progress.report(1)
            return .live(recognizer)
        }
        // The VAD is ~2 MB; give it a sliver of the bar.
        let detector = try await VoiceActivityDetector.load(cacheBase: base) { progress.report(0.02 * $0) }
        let recognizer = try await recognizerType.load(
            repositoryID: model.repositoryID,
            cacheBase: base
        ) { progress.report(0.02 + 0.98 * $0) }
        progress.report(1)
        return .offline(detector: detector, recognizer: recognizer)
    }

    private static func defaultModelDirectory() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            throw TranscriptionError.modelUnavailable("Application Support directory not found")
        }
        return support.appendingPathComponent("Mixdown/Models", isDirectory: true)
    }

    private static func unavailable(_ error: any Error) -> TranscriptionError {
        if let error = error as? TranscriptionError { return error }
        return .modelUnavailable(error.localizedDescription)
    }

    // MARK: - Transcription

    /// Runs `operation` after every earlier transcription has finished. The model instances aren't
    /// thread-safe, and actor reentrancy alone would let a second transcription interleave at the
    /// `await`s. Cancelling the caller cancels its job.
    private func oneAtATime<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = lastTranscription
        let job = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        lastTranscription = Task { _ = await job.result }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    private func performTranscription(
        _ samples: [Float],
        options: TranscriptionOptions,
        language: String?
    ) async throws -> Transcript {
        guard case .offline(let detector, let recognizer) = try await loadedModels(progress: nil) else {
            throw TranscriptionError.failed("\(model.displayName) transcribes while recording")
        }
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let audioDuration = Double(samples.count) / AudioChunk.sampleRate

        let hint = language.flatMap { recognizer.languageHint(forISOCode: $0) }
        if let language, hint == nil {
            transcriptionLogger.info(
                "\(self.model.displayName, privacy: .public) takes no language hint for '\(language, privacy: .public)'; detecting automatically"
            )
        }
        if options.translateToEnglish, !hasLoggedTranslationNotice {
            hasLoggedTranslationNotice = true
            transcriptionLogger.debug("speech-swift models don't translate; transcribing verbatim")
        }

        // The VAD and recognizer calls below are synchronous and run on this actor. That's fine: the
        // actor has no other work while transcribing, and `info` is nonisolated. Cancellation is checked
        // inside the VAD, between pieces and (for Qwen3-ASR) between decoded tokens.
        let detection = try detector.detect(samples)
        let pieces = SpeechChunker.pieces(
            regions: detection.regions,
            probabilities: detection.probabilities,
            frameDuration: VoiceActivityDetector.frameDuration,
            audioDuration: audioDuration,
            configuration: recognizer.chunking
        )
        guard !pieces.isEmpty else {
            transcriptionLogger.info("No speech detected in \(audioDuration, format: .fixed(precision: 1)) s of audio")
            return Transcript(segments: [], language: language)
        }

        var segments: [TranscriptSegment] = []
        for piece in pieces {
            try Task.checkCancellation()
            let audio = Self.slice(samples, to: piece.window)
            guard !audio.isEmpty else { continue }
            let recognized: [RecognizedSegment]
            do {
                recognized = try recognizer.recognize(audio, languageHint: hint)
            } catch let error as CancellationError {
                throw error
            } catch {
                throw TranscriptionError.failed(error.localizedDescription)
            }
            segments.append(contentsOf: recognized.compactMap { piece.place($0) })
            await Task.yield()
        }

        transcriptionLogger.info(
            "Transcribed \(audioDuration, format: .fixed(precision: 1)) s in \(pieces.count) pieces, \(segments.count) segments, \(String(describing: ContinuousClock.now - started), privacy: .public)"
        )
        return Transcript(segments: segments, language: language)
    }

    private static func slice(_ samples: [Float], to span: TimeSpan) -> [Float] {
        let lower = max(0, Int((span.start * AudioChunk.sampleRate).rounded(.down)))
        let upper = min(samples.count, Int((span.end * AudioChunk.sampleRate).rounded(.up)))
        return lower < upper ? Array(samples[lower..<upper]) : []
    }

    /// `"de-DE"` → `"de"`. `nil` for nil or empty input.
    private static func languageCode(_ language: String?) -> String? {
        guard let language else { return nil }
        let primary = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        return primary.map(String.init)
    }
}

/// Fans load progress out to every `prepare` caller, never moving backwards.
private final class ProgressRelay: Sendable {
    private struct State {
        var observers: [@Sendable (Double) -> Void] = []
        var value: Double = 0
    }

    private let state = Mutex(State())

    func add(_ observer: @escaping @Sendable (Double) -> Void) {
        let value = state.withLock {
            $0.observers.append(observer)
            return $0.value
        }
        observer(value)
    }

    func report(_ fraction: Double) {
        let (observers, value) = state.withLock { current -> ([@Sendable (Double) -> Void], Double) in
            current.value = max(current.value, min(max(fraction, 0), 1))
            return (current.observers, current.value)
        }
        observers.forEach { $0(value) }
    }
}
