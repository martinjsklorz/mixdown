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
    /// The same microphones after the USB one became the default input.
    static let usbMicAsDefault = AudioInputDevice(id: "usb", name: "USB Microphone", kind: .microphone, isDefault: true)
    static let builtInMicNotDefault = AudioInputDevice(id: "builtin", name: "MacBook Pro Microphone", kind: .microphone)

    static func chunk(
        seconds: Double,
        startTime: TimeInterval = 0,
        hostTime: TimeInterval? = nil,
        amplitude: Float = 0.1
    ) -> AudioChunk {
        AudioChunk(
            samples: Array(repeating: amplitude, count: Int(seconds * AudioChunk.sampleRate)),
            startTime: startTime,
            hostTime: hostTime
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

/// A device list that changes while the test runs, like devices being plugged in and out.
final class LiveDeviceProvider: AudioDeviceProvider {
    private let devices: LockedValue<[AudioInputDevice]>
    private let subscribers = LockedValue<[AsyncStream<[AudioInputDevice]>.Continuation]>([])

    init(devices: [AudioInputDevice]) {
        self.devices = LockedValue(devices)
    }

    func availableDevices() async -> [AudioInputDevice] { devices.current }

    func deviceUpdates() -> AsyncStream<[AudioInputDevice]> {
        let (stream, continuation) = AsyncStream<[AudioInputDevice]>.makeStream()
        subscribers.update { $0.append(continuation) }
        return stream
    }

    /// Changes the device list and reports it to subscribers.
    func send(_ list: [AudioInputDevice]) {
        devices.update { $0 = list }
        for subscriber in subscribers.current {
            subscriber.yield(list)
        }
    }
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

    /// Delivers another chunk while recording.
    func yield(_ chunk: AudioChunk) {
        continuation.yield(chunk)
    }

    func stop() async {
        stopCalls.update { $0 += 1 }
        continuation.finish()
    }
}

/// Hands out the next of the captures queued for a device's ID, then the capture registered for
/// it, else `capture`. Queue several for a device that's recorded from more than once, as
/// captures are single-use.
struct MockCaptureFactory: AudioCaptureFactory {
    let capture: MockCapture
    var captures: [String: MockCapture] = [:]
    let queuedCaptures: LockedValue<[String: [MockCapture]]>
    let requestedDevices = LockedValue<[AudioInputDevice]>([])

    init(capture: MockCapture, captures: [String: MockCapture] = [:], queuedCaptures: [String: [MockCapture]] = [:]) {
        self.capture = capture
        self.captures = captures
        self.queuedCaptures = LockedValue(queuedCaptures)
    }

    func makeCapture(for device: AudioInputDevice) throws -> any AudioCapturing {
        requestedDevices.update { $0.append(device) }
        var queued: MockCapture?
        queuedCaptures.update { queue in
            if queue[device.id]?.isEmpty == false {
                queued = queue[device.id]?.removeFirst()
            }
        }
        return queued ?? captures[device.id] ?? capture
    }
}

/// Reports whether other apps play audio as `isPlaying` says.
struct MockPlaybackMonitor: AudioPlaybackMonitoring {
    let isPlaying = LockedValue(false)

    func isOtherAudioPlaying() async -> Bool { isPlaying.current }
}

actor MockEngine: TranscriptionEngine {
    nonisolated let info = TranscriptionEngineInfo(id: "mock", displayName: "Mock Engine")
    nonisolated var isDownloaded: Bool { downloaded.current }

    private let transcript: Transcript
    /// Returned instead of `transcript` for a given sample count, to tell sources apart.
    private let transcriptsBySampleCount: [Int: Transcript]
    private let transcribeError: (any Error)?
    private let progressBySampleCount: [Int: Double]
    private let transcriptionGate: Gate?
    private let prepareError: (any Error)?
    private let preparesUntilCancelled: Bool
    private let deleteError: (any Error)?
    private nonisolated let downloaded: LockedValue<Bool>
    private(set) var receivedSampleCounts: [Int] = []
    private(set) var prepareCount = 0
    private(set) var cancelledPrepareCount = 0
    private(set) var deleteCount = 0

    /// - Parameters:
    ///   - isDownloaded: Whether the model starts out on disk. A successful `prepare` downloads it.
    ///   - preparesUntilCancelled: `prepare` stalls halfway, like a slow download, until its task
    ///     is cancelled.
    ///   - deleteError: Thrown by `deleteModel`, which then leaves the model on disk.
    ///   - progressBySampleCount: Progress `transcribe` reports for a given sample count before
    ///     waiting for `transcriptionGate`.
    ///   - transcriptionGate: `transcribe` returns once it opens.
    init(
        transcript: Transcript = Transcript(segments: []),
        transcriptsBySampleCount: [Int: Transcript] = [:],
        transcribeError: (any Error)? = nil,
        progressBySampleCount: [Int: Double] = [:],
        transcriptionGate: Gate? = nil,
        isDownloaded: Bool = true,
        prepareError: (any Error)? = nil,
        preparesUntilCancelled: Bool = false,
        deleteError: (any Error)? = nil
    ) {
        self.transcript = transcript
        self.transcriptsBySampleCount = transcriptsBySampleCount
        self.transcribeError = transcribeError
        self.progressBySampleCount = progressBySampleCount
        self.transcriptionGate = transcriptionGate
        self.downloaded = LockedValue(isDownloaded)
        self.prepareError = prepareError
        self.preparesUntilCancelled = preparesUntilCancelled
        self.deleteError = deleteError
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

    func deleteModel() async throws {
        deleteCount += 1
        if let deleteError { throw deleteError }
        downloaded.update { $0 = false }
    }

    func transcribe(
        _ samples: [Float],
        options: TranscriptionOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        receivedSampleCounts.append(samples.count)
        if let fraction = progressBySampleCount[samples.count] { progress?(fraction) }
        await transcriptionGate?.wait()
        if let transcribeError { throw transcribeError }
        return transcriptsBySampleCount[samples.count] ?? transcript
    }
}

/// Holds callers of `wait()` until `open()`.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
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

/// Returns `summary`, or throws `error`, and records the transcripts it was given.
final class MockSummarizer: Summarizer {
    let info = SummarizerInfo(id: "mock", displayName: "Mock Summarizer")
    let availability: SummarizerAvailability
    private let summary: NoteSummary
    private let error: (any Error)?
    private let received = LockedValue<[Transcript]>([])

    init(
        summary: NoteSummary = NoteSummary(overview: "A test."),
        error: (any Error)? = nil,
        availability: SummarizerAvailability = .available
    ) {
        self.summary = summary
        self.error = error
        self.availability = availability
    }

    var receivedTranscripts: [Transcript] { received.current }

    func summarize(_ transcript: Transcript) async throws -> NoteSummary {
        received.update { $0.append(transcript) }
        if let error { throw error }
        return summary
    }
}
