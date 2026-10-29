@preconcurrency internal import AudioCommon
import Foundation
internal import MLX
import MixdownCore
@preconcurrency internal import SpeechVAD
import Synchronization
import os

private let logger = Logger(subsystem: "app.mixdown", category: "speakers")

/// Tells speakers apart with NVIDIA's Nemotron 3 Diarization (int8, on MLX) from speech-swift: up
/// to eight speakers, in steps of 10 ms, from the voices alone. The model (about 100 MB) is
/// downloaded the first time, loaded for each recording and freed again right after, as it's
/// needed only once a recording ends.
///
/// An hour of audio takes seconds, plus up to a few hundred MB of memory while it runs.
public final class NemotronSpeakerDiarizer: SpeakerDiarizer {
    /// Loads a model instance, downloading it first if need be.
    typealias Load =
        @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws
        -> any SpeakerDiarizationModel

    static let cachedModel = CachedModel(
        repositoryID: Nemotron3Diarizer.defaultMLXModelId,
        requiredFiles: ["config.json"]
    )

    private let modelIsOnDisk: @Sendable () -> Bool
    private let load: Load
    private let clearCache: @Sendable () -> Void
    /// The load under way while the model isn't on disk, i.e. its download, which other callers
    /// wait for rather than download the same files.
    private let download = Mutex<Task<any SpeakerDiarizationModel, any Error>?>(nil)

    public convenience init() {
        self.init(
            isOnDisk: {
                guard let base = ModelDirectory.url else { return false }
                return Self.cachedModel.isDownloaded(base: base)
            },
            load: { progress in try await Self.loadNemotron(progress: progress) },
            clearCache: { Memory.clearCache() }
        )
    }

    /// - Parameters:
    ///   - isOnDisk: Whether the model is downloaded; checking files only.
    ///   - load: Loads an instance, downloading the model if it isn't on disk.
    ///   - clearCache: Empties the buffer cache freed weights land in.
    init(
        isOnDisk: @escaping @Sendable () -> Bool,
        load: @escaping Load,
        clearCache: @escaping @Sendable () -> Void
    ) {
        self.modelIsOnDisk = isOnDisk
        self.load = load
        self.clearCache = clearCache
    }

    public var isDownloaded: Bool { modelIsOnDisk() }

    /// Downloads the model if it isn't on disk.
    public func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        guard !isDownloaded else { return }
        _ = try await sharedDownload(progress: progress ?? { _ in })
        // Freed weights land in MLX's buffer cache, which would keep holding the memory.
        clearCache()
    }

    public func deleteModel() async throws {
        guard let base = ModelDirectory.url,
            let directory = ModelCache.existingDirectory(for: Self.cachedModel.repositoryID, base: base)
        else { return }
        try FileManager.default.removeItem(at: directory)
        logger.info("Deleted \(Self.cachedModel.repositoryID, privacy: .public)")
    }

    public func diarize(_ samples: [Float]) async throws -> [SpeakerTurn] {
        guard !samples.isEmpty else { return [] }
        let started = ContinuousClock.now
        // In a function of its own, so the model is gone by the time the cache is cleared.
        func run() async throws -> [SpeakerTurn] {
            let model = try await loadedModel()
            try Task.checkCancellation()
            return try await Self.diarize(samples, with: model)
        }
        // Freed weights land in MLX's buffer cache, which would keep holding the memory.
        defer { clearCache() }
        let turns = try await run()
        logger.info(
            "Found \(Set(turns.map(\.speaker)).count) speakers in \(Double(samples.count) / AudioChunk.sampleRate, format: .fixed(precision: 0)) s of audio in \(String(describing: ContinuousClock.now - started), privacy: .public)"
        )
        return turns
    }

    // MARK: - Loading

    /// A model instance of this call's own. Without the model on disk, it downloads it, or waits
    /// for the download under way and then loads from disk: an instance runs one diarization at a
    /// time, so it isn't shared with another caller.
    private func loadedModel() async throws -> any SpeakerDiarizationModel {
        if !isDownloaded {
            let download = try await sharedDownload(progress: { _ in })
            if download.isOwn { return download.model }
        }
        return try await load { _ in }
    }

    /// Loads the model, joining the load under way if there is one, which is the download when the
    /// model isn't on disk. Cancelling stops it for every caller waiting on it; files already on
    /// disk are kept, so the next call resumes.
    /// - Returns: The model, and whether this call started its load.
    private func sharedDownload(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (model: any SpeakerDiarizationModel, isOwn: Bool) {
        while true {
            let (task, isOwn) = download.withLock { slot in
                if let slot { return (slot, false) }
                let task = Task { [load] in try await load(progress) }
                slot = task
                return (task, true)
            }
            if isOwn {
                defer { download.withLock { if $0 == task { $0 = nil } } }
                let model = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                return (model, true)
            }
            do {
                return (try await task.value, false)
            } catch let error where !(error is CancellationError) || Task.isCancelled {
                throw error
            } catch {
                // Whoever started it cancelled it, e.g. in Settings; this caller still needs it.
                download.withLock { if $0 == task { $0 = nil } }
            }
        }
    }

    /// Runs the model on a thread of its own: it takes seconds for an hour of audio, and would
    /// otherwise hold one of the few threads all of Swift's tasks share.
    private static func diarize(
        _ samples: [Float],
        with model: any SpeakerDiarizationModel
    ) async throws -> [SpeakerTurn] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try model.diarize(samples) })
            }
        }
    }

    /// Loads from the cache, else downloads. Throws `TranscriptionError.modelUnavailable`.
    private static func loadNemotron(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> any SpeakerDiarizationModel {
        do {
            let diarizer = try await cachedModel.load(
                base: SpeechSwiftEngine.modelDirectory(),
                progress: progress
            ) { directory, offline, progress in
                try await Nemotron3Diarizer.fromMLXPretrained(
                    cacheDir: directory,
                    offlineMode: offline,
                    progressHandler: { fraction, _ in progress(fraction) }
                )
            }
            return NemotronDiarizationModel(diarizer: diarizer)
        } catch {
            let error = TranscriptionError.unavailableOrCancelled(error)
            if !(error is CancellationError) {
                logger.error("Loading speaker detection failed: \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }
}

/// A loaded diarization model, so tests can stand in for Nemotron.
protocol SpeakerDiarizationModel: AnyObject, Sendable {
    /// Who spoke when in 16 kHz mono samples. Synchronous and GPU-bound.
    func diarize(_ samples: [Float]) throws -> [SpeakerTurn]
}

/// `@unchecked Sendable`: each instance belongs to one caller of `NemotronSpeakerDiarizer`, which
/// makes one call at a time.
private final class NemotronDiarizationModel: SpeakerDiarizationModel, @unchecked Sendable {
    private let diarizer: Nemotron3Diarizer

    init(diarizer: Nemotron3Diarizer) {
        self.diarizer = diarizer
    }

    func diarize(_ samples: [Float]) throws -> [SpeakerTurn] {
        try diarizer.diarize(audio: samples, sampleRate: Int(AudioChunk.sampleRate)).segments.map {
            SpeakerTurn(start: TimeInterval($0.startTime), end: TimeInterval($0.endTime), speaker: $0.speakerId)
        }
    }
}
