import Foundation
internal import MLX
import MixdownCore
import Synchronization
import os

/// On-device transcription with [speech-swift](https://github.com/soniqo/speech-swift) on MLX.
///
/// Silero VAD finds the speech; each `SpeechSwiftModel` decides how to cut it and how to turn a piece
/// into timed segments (see `SpeechRecognizer`). Transcriptions run one at a time. The models are
/// loaded on first use and unloaded again once the engine has been idle for `idleUnloadDelay`.
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
    private nonisolated let idleUnloadDelay: Duration
    private var models: LoadedModels?
    private var loading: (task: Task<LoadedModels, any Error>, progress: ProgressRelay)?
    private var lastTranscription: Task<Void, Never>?
    /// Transcriptions running or queued, and live sessions open. The models stay loaded while
    /// there are any.
    private var activeTranscriptions = 0
    private var pendingUnload: Task<Void, Never>?
    /// Seconds of audio per second of recognition, as last measured on this Mac.
    private var measuredSpeed: Double?
    private var hasLoggedTranslationNotice = false

    /// - Parameters:
    ///   - modelDirectory: Where weights are cached. Defaults to `Application Support/Mixdown/Models`
    ///     (inside the container when sandboxed).
    ///   - idleUnloadDelay: How long the models stay in memory after the last transcription (or
    ///     `prepare`). Loading them again from disk takes seconds; keeping them costs 1–2.5 GB.
    public init(
        model: SpeechSwiftModel = .default,
        modelDirectory: URL? = nil,
        idleUnloadDelay: Duration = .seconds(120)
    ) {
        self.model = model
        self.modelDirectory = modelDirectory
        self.idleUnloadDelay = idleUnloadDelay
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
        scheduleUnload()
    }

    /// Transcribes a whole recording of 16 kHz mono samples. Segments follow the VAD's speech regions
    /// (or the model's own timestamps for MOSS). `translateToEnglish` is not supported and ignored.
    /// Throws for the live model, which transcribes while recording instead.
    ///
    /// `progress` covers the VAD pass, then the pieces by length. Within a piece it moves on an
    /// estimate of the model's speed on this Mac, since the recognizers don't report progress.
    public func transcribe(
        _ samples: [Float],
        options: TranscriptionOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        let progress = progress.map { MonotonicProgress($0) }
        // A model that detects the language itself ignores the setting, so the note mustn't claim it.
        let language = model.supportsLanguageSelection ? Self.languageCode(options.language) : nil
        guard !samples.isEmpty else {
            progress?.report(1)
            return Transcript(segments: [], language: language)
        }
        activeTranscriptions += 1
        pendingUnload?.cancel()
        defer {
            activeTranscriptions -= 1
            scheduleUnload()
        }
        let transcript = try await oneAtATime {
            try await self.performTranscription(samples, options: options, language: language, progress: progress)
        }
        // Also when there was no speech, so a silent source doesn't hold the bar back.
        progress?.report(1)
        return transcript
    }

    /// A session for one input of a recording; see `LiveRecognizer`. Loads the model if it isn't
    /// yet. Throws `TranscriptionError` for offline models or if the session can't start.
    public func makeLiveSession(options: TranscriptionOptions) async throws -> any LiveTranscriptionSession {
        guard case .live(let recognizer) = try await loadedModels(progress: nil) else {
            throw TranscriptionError.failed("\(model.displayName) transcribes once the recording ends")
        }
        let state: LiveSessionState
        do {
            state = try recognizer.makeSession(languageCode: Self.languageCode(options.language))
        } catch {
            throw TranscriptionError.failed(error.localizedDescription)
        }
        // Open until it finishes or fails; a recording can outlast `idleUnloadDelay`.
        activeTranscriptions += 1
        pendingUnload?.cancel()
        return SpeechSwiftLiveSession(engine: self, state: state)
    }

    // A live session's calls. Synchronous, so no other model call on this actor runs meanwhile.

    func push(_ samples: [Float], into state: LiveSessionState) throws -> LiveTranscriptUpdate {
        do {
            return try state.push(samples)
        } catch {
            close(state)
            throw TranscriptionError.failed(error.localizedDescription)
        }
    }

    func finish(_ state: LiveSessionState) throws -> LiveTranscriptUpdate {
        defer { close(state) }
        do {
            return try state.finish()
        } catch {
            throw TranscriptionError.failed(error.localizedDescription)
        }
    }

    /// Ends `state`'s claim on the models, once.
    private func close(_ state: LiveSessionState) {
        guard state.isOpen else { return }
        state.isOpen = false
        activeTranscriptions -= 1
        scheduleUnload()
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
        unload()
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

    // MARK: - Unloading

    /// Unloads the models after `idleUnloadDelay`, unless a transcription comes first.
    private func scheduleUnload() {
        pendingUnload?.cancel()
        guard activeTranscriptions == 0, models != nil else { return }
        let delay = idleUnloadDelay
        pendingUnload = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard activeTranscriptions == 0, loading == nil, models != nil else { return }
        unload()
        transcriptionLogger.info("Unloaded \(self.model.displayName, privacy: .public) after being idle")
    }

    private func unload() {
        pendingUnload?.cancel()
        pendingUnload = nil
        if case .offline(_, let recognizer) = models { recognizer.unload() }
        models = nil
        // Freed weights land in MLX's buffer cache, which would keep holding the memory.
        Memory.clearCache()
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
        language requestedLanguage: String?,
        progress: MonotonicProgress?
    ) async throws -> Transcript {
        guard case .offline(let detector, let recognizer) = try await loadedModels(progress: nil) else {
            throw TranscriptionError.failed("\(model.displayName) transcribes while recording")
        }
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let audioDuration = Double(samples.count) / AudioChunk.sampleRate

        let hint = requestedLanguage.flatMap { recognizer.languageHint(forISOCode: $0) }
        if let requestedLanguage, hint == nil {
            transcriptionLogger.info(
                "\(self.model.displayName, privacy: .public) takes no language hint for '\(requestedLanguage, privacy: .public)'; detecting automatically"
            )
        }
        // Only a language the model was told to use is known; the detected one isn't reported.
        let language = hint == nil ? nil : requestedLanguage
        if options.translateToEnglish, !hasLoggedTranslationNotice {
            hasLoggedTranslationNotice = true
            transcriptionLogger.debug("speech-swift models don't translate; transcribing verbatim")
        }

        // The VAD and recognizer calls below are synchronous and run on this actor. That's fine: the
        // actor has no other work while transcribing, and `info` is nonisolated. Cancellation is checked
        // inside the VAD, between pieces and (for Qwen3-ASR) between decoded tokens.
        let detection = try detector.detect(samples) { progress?.report(RecognitionProgress.detection($0)) }
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

        let plan = RecognitionProgress(pieceDurations: pieces.map(\.window.duration))
        var speed = measuredSpeed ?? model.expectedSpeed
        var recognizedDuration = 0.0
        var recognitionTime = 0.0
        var segments: [TranscriptSegment] = []
        for (index, piece) in pieces.enumerated() {
            try Task.checkCancellation()
            let audio = Self.slice(samples, to: piece.window)
            if !audio.isEmpty {
                let pieceStarted = ContinuousClock.now
                let ticker = progress.map {
                    Self.estimateProgress(of: index, in: plan, expected: piece.window.duration / speed, reportingTo: $0)
                }
                let recognized: [RecognizedSegment]
                do {
                    defer { ticker?.cancel() }
                    recognized = try recognizer.recognize(audio, languageHint: hint)
                } catch let error as CancellationError {
                    throw error
                } catch {
                    throw TranscriptionError.failed(error.localizedDescription)
                }
                segments.append(contentsOf: recognized.compactMap { piece.place($0) })

                recognizedDuration += piece.window.duration
                recognitionTime += Self.seconds(ContinuousClock.now - pieceStarted)
                if recognitionTime > 0 {
                    speed = recognizedDuration / recognitionTime
                }
            }
            progress?.report(plan.completed(index + 1))
            await Task.yield()
        }
        // Too little audio says more about warm-up than about speed.
        if recognizedDuration >= 30 { measuredSpeed = speed }

        transcriptionLogger.info(
            "Transcribed \(audioDuration, format: .fixed(precision: 1)) s in \(pieces.count) pieces, \(segments.count) segments, \(String(describing: ContinuousClock.now - started), privacy: .public)"
        )
        return Transcript(segments: segments, language: language)
    }

    /// Reports `plan.running(index, …)` twice a second until cancelled, i.e. while the
    /// recognizer (which blocks this actor) works on the piece.
    private static func estimateProgress(
        of index: Int,
        in plan: RecognitionProgress,
        expected: TimeInterval,
        reportingTo progress: MonotonicProgress
    ) -> Task<Void, Never> {
        let started = ContinuousClock.now
        return Task.detached {
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                progress.report(plan.running(index, elapsed: seconds(ContinuousClock.now - started), expected: expected))
            }
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) * 1e-18
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

/// Forwards transcription progress, never moving backwards: the estimate for a piece can arrive
/// after the piece has finished.
private final class MonotonicProgress: Sendable {
    private let forward: @Sendable (Double) -> Void
    private let value = Mutex(-1.0)

    init(_ forward: @escaping @Sendable (Double) -> Void) {
        self.forward = forward
    }

    func report(_ fraction: Double) {
        guard fraction.isFinite else { return }
        let fraction = min(max(fraction, 0), 1)
        // Forwarded inside the lock, so two threads can't deliver out of order.
        value.withLock {
            guard fraction > $0 else { return }
            $0 = fraction
            forward(fraction)
        }
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
