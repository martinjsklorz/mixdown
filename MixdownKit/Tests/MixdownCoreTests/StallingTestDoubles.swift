import Foundation
import MixdownCore

/// Like `MockCapture`, but `stop()` waits for `stopGate` to open before the stream finishes, like
/// a device that takes its time to stop.
final class StallingCapture: AudioCapturing {
    let stopGate = Gate()
    private let chunks: [AudioChunk]
    private let stream: AsyncThrowingStream<AudioChunk, any Error>
    private let continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation
    private let stopCalls = LockedValue(0)

    init(chunks: [AudioChunk] = []) {
        self.chunks = chunks
        (stream, continuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
    }

    var stopCount: Int { stopCalls.current }

    func start() async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        for chunk in chunks {
            continuation.yield(chunk)
        }
        return stream
    }

    func yield(_ chunk: AudioChunk) {
        continuation.yield(chunk)
    }

    func stop() async {
        stopCalls.update { $0 += 1 }
        await stopGate.wait()
        continuation.finish()
    }
}

/// A live session that takes `pushDelay` over every push, like a model working through a backlog.
actor SlowLiveSession: LiveTranscriptionSession {
    private let pushDelay: Duration
    private nonisolated let pushes = LockedValue(0)
    private(set) var finishCount = 0

    init(pushDelay: Duration) {
        self.pushDelay = pushDelay
    }

    /// Pushes begun so far.
    nonisolated var pushCount: Int { pushes.current }

    func push(_ samples: [Float]) async throws -> LiveTranscriptUpdate {
        pushes.update { $0 += 1 }
        try await Task.sleep(for: pushDelay)
        return LiveTranscriptUpdate()
    }

    func finish() async throws -> LiveTranscriptUpdate {
        finishCount += 1
        return LiveTranscriptUpdate()
    }
}

/// An engine that transcribes live with `session`.
struct LiveEngine: TranscriptionEngine {
    let info = TranscriptionEngineInfo(id: "live", displayName: "Live Engine")
    let isDownloaded = true
    let transcribesLive = true
    let session: any LiveTranscriptionSession

    func makeLiveSession(options: TranscriptionOptions) async throws -> any LiveTranscriptionSession { session }
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {}
    func deleteModel() async throws {}

    func transcribe(
        _ samples: [Float],
        options: TranscriptionOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        Transcript(segments: [])
    }
}
