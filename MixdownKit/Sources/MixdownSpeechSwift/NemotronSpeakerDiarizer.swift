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
    static let repositoryID = Nemotron3Diarizer.defaultMLXModelId

    /// The download under way, which other callers wait for rather than download the same files.
    private let download = Mutex<Task<Void, any Error>?>(nil)

    public init() {}

    public var isDownloaded: Bool {
        guard let directory = try? Self.directory() else { return false }
        return Self.cacheLooksComplete(in: directory)
    }

    /// Downloads the model if it isn't on disk.
    public func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        try await downloadIfMissing(progress: progress ?? { _ in })
    }

    public func deleteModel() async throws {
        try FileManager.default.removeItem(at: Self.directory())
        logger.info("Deleted \(Self.repositoryID, privacy: .public)")
    }

    public func diarize(_ samples: [Float]) async throws -> [SpeakerTurn] {
        guard !samples.isEmpty else { return [] }
        let started = ContinuousClock.now
        try await downloadIfMissing(progress: { _ in })
        let diarizer = try await Self.load(progress: { _ in })
        try Task.checkCancellation()
        // Freed weights land in MLX's buffer cache, which would keep holding the memory.
        defer { Memory.clearCache() }
        let result = try diarizer.diarize(audio: samples, sampleRate: Int(AudioChunk.sampleRate))
        logger.info(
            "Found \(result.numSpeakers) speakers in \(Double(samples.count) / AudioChunk.sampleRate, format: .fixed(precision: 0)) s of audio in \(String(describing: ContinuousClock.now - started), privacy: .public)"
        )
        return result.segments.map {
            SpeakerTurn(start: TimeInterval($0.startTime), end: TimeInterval($0.endTime), speaker: $0.speakerId)
        }
    }

    // MARK: - Loading

    /// Downloads the model unless it's on disk, joining a download under way. Cancelling stops it
    /// for every caller waiting on it; files already on disk are kept, so the next call resumes.
    private func downloadIfMissing(progress: @escaping @Sendable (Double) -> Void) async throws {
        if let pending = download.withLock({ $0 }) {
            do {
                try await pending.value
                return
            } catch where !(error is CancellationError) || Task.isCancelled {
                throw error
            } catch {
                // Whoever started it cancelled it, e.g. in Settings; this caller still needs it.
            }
        }
        guard !isDownloaded else { return }
        let task = Task {
            _ = try await Self.load(progress: progress)
            Memory.clearCache()
        }
        download.withLock { $0 = task }
        defer { download.withLock { if $0 == task { $0 = nil } } }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Loads from the cache, else downloads. Throws `TranscriptionError.modelUnavailable`.
    private static func load(progress: @escaping @Sendable (Double) -> Void) async throws -> Nemotron3Diarizer {
        do {
            let directory = try Self.directory()
            return try await ModelCache.loadPreferringCache(
                repositoryID,
                cacheLooksComplete: cacheLooksComplete(in: directory),
                progress: progress
            ) { offline, progress in
                try await Nemotron3Diarizer.fromMLXPretrained(
                    cacheDir: directory,
                    offlineMode: offline,
                    progressHandler: { fraction, _ in progress(fraction) }
                )
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            logger.error("Loading speaker detection failed: \(String(describing: error), privacy: .public)")
            throw TranscriptionError.unavailable(error)
        }
    }

    private static func directory() throws -> URL {
        try ModelCache.directory(for: repositoryID, base: SpeechSwiftEngine.modelDirectory())
    }

    private static func cacheLooksComplete(in directory: URL) -> Bool {
        ModelCache.contains(weightsAnd: ["config.json"], in: directory)
    }
}
