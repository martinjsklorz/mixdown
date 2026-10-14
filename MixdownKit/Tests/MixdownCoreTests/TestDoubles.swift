import Foundation
import MixdownCore
import Testing

enum Fixtures {
    static let startDate = Date(timeIntervalSince1970: 1_760_000_000)
    static let builtInMic = AudioInputDevice(
        id: "builtin", name: "MacBook Pro Microphone", kind: .microphone, isDefault: true
    )
    static let usbMic = AudioInputDevice(id: "usb", name: "USB Microphone", kind: .microphone)
    static let devices = [usbMic, builtInMic, AudioInputDevice.systemAudio]

    static func chunk(seconds: Double, startTime: TimeInterval = 0) -> AudioChunk {
        AudioChunk(
            samples: Array(repeating: 0.1, count: Int(seconds * AudioChunk.sampleRate)),
            startTime: startTime
        )
    }
}

/// Minimal thread-safe box for recording calls made from non-isolated contexts.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var current: Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&value)
    }
}

/// Returns a fixed device list; `updates` are buffered and the stream finishes right away,
/// so `monitorDevices()` processes them all and returns.
struct MockDeviceProvider: AudioDeviceProvider {
    let devices: [AudioInputDevice]
    private let updates: AsyncStream<[AudioInputDevice]>

    init(devices: [AudioInputDevice], updates: [[AudioInputDevice]] = []) {
        self.devices = devices
        let (stream, continuation) = AsyncStream<[AudioInputDevice]>.makeStream()
        for update in updates {
            continuation.yield(update)
        }
        continuation.finish()
        self.updates = stream
    }

    func availableDevices() async -> [AudioInputDevice] { devices }
    func deviceUpdates() -> AsyncStream<[AudioInputDevice]> { updates }
}

/// Yields `chunks` on start, then finishes on `stop()` (or immediately with `streamError`, or
/// immediately without error when `finishesOnStart`, like a capture the system ended).
final class MockCapture: AudioCapturing {
    private let chunks: [AudioChunk]
    private let streamError: (any Error)?
    private let startError: (any Error)?
    private let finishesOnStart: Bool
    private let stream: AsyncThrowingStream<AudioChunk, any Error>
    private let continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation
    private let stopCalls = LockedValue(0)

    init(
        chunks: [AudioChunk] = [],
        streamError: (any Error)? = nil,
        startError: (any Error)? = nil,
        finishesOnStart: Bool = false
    ) {
        self.chunks = chunks
        self.streamError = streamError
        self.startError = startError
        self.finishesOnStart = finishesOnStart
        let (stream, continuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    var stopCount: Int { stopCalls.current }

    func start() async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        if let startError { throw startError }
        for chunk in chunks {
            continuation.yield(chunk)
        }
        if let streamError {
            continuation.finish(throwing: streamError)
        } else if finishesOnStart {
            continuation.finish()
        }
        return stream
    }

    func stop() async {
        stopCalls.update { $0 += 1 }
        continuation.finish()
    }
}

struct MockCaptureFactory: AudioCaptureFactory {
    let capture: MockCapture
    let requestedDevices = LockedValue<[AudioInputDevice]>([])

    func makeCapture(for device: AudioInputDevice) throws -> any AudioCapturing {
        requestedDevices.update { $0.append(device) }
        return capture
    }
}

actor MockEngine: TranscriptionEngine {
    nonisolated let info = TranscriptionEngineInfo(id: "mock", displayName: "Mock Engine")
    nonisolated var isDownloaded: Bool { downloaded.current }

    private let transcript: Transcript
    private let transcribeError: (any Error)?
    private let prepareError: (any Error)?
    private let preparesUntilCancelled: Bool
    private nonisolated let downloaded: LockedValue<Bool>
    private(set) var receivedSampleCounts: [Int] = []
    private(set) var prepareCount = 0
    private(set) var cancelledPrepareCount = 0

    /// - Parameters:
    ///   - isDownloaded: Whether the model starts out on disk. A successful `prepare` downloads it.
    ///   - preparesUntilCancelled: `prepare` stalls halfway, like a slow download, until its task
    ///     is cancelled.
    init(
        transcript: Transcript = Transcript(segments: []),
        transcribeError: (any Error)? = nil,
        isDownloaded: Bool = true,
        prepareError: (any Error)? = nil,
        preparesUntilCancelled: Bool = false
    ) {
        self.transcript = transcript
        self.transcribeError = transcribeError
        self.downloaded = LockedValue(isDownloaded)
        self.prepareError = prepareError
        self.preparesUntilCancelled = preparesUntilCancelled
    }

    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        prepareCount += 1
        progress?(0.5)
        if preparesUntilCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelledPrepareCount += 1
                throw error
            }
        }
        if let prepareError { throw prepareError }
        downloaded.update { $0 = true }
        progress?(1)
    }

    func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> Transcript {
        receivedSampleCounts.append(samples.count)
        if let transcribeError { throw transcribeError }
        return transcript
    }
}

actor InMemoryNoteWriter: NoteWriting {
    private(set) var notes: [Note] = []

    func write(_ note: Note) async throws -> URL {
        notes.append(note)
        return URL(fileURLWithPath: "/tmp/mixdown-test-\(notes.count).md")
    }
}

/// Polls `condition` on the main actor, recording an issue on timeout.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else {
            Issue.record("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
