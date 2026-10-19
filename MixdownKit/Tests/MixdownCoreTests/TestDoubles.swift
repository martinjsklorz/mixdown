import Foundation
import MixdownCore
import Testing

enum Fixtures {
    static let startDate = Date(timeIntervalSince1970: 1_760_000_000)
    static let builtInMic = AudioInputDevice(
        id: "builtin",
        name: "MacBook Pro Microphone",
        kind: .microphone,
        isDefault: true
    )
    static let usbMic = AudioInputDevice(id: "usb", name: "USB Microphone", kind: .microphone)
    static let devices = [usbMic, builtInMic, AudioInputDevice.systemAudio]
    /// The same microphones after the USB one became the default input.
    static let usbMicAsDefault = AudioInputDevice(id: "usb", name: "USB Microphone", kind: .microphone, isDefault: true)
    static let builtInMicNotDefault = AudioInputDevice(id: "builtin", name: "MacBook Pro Microphone", kind: .microphone)

    static func chunk(
        seconds: Double,
        hostTime: TimeInterval? = nil,
        amplitude: Float = 0.1
    ) -> AudioChunk {
        AudioChunk(
            samples: Array(repeating: amplitude, count: Int(seconds * AudioChunk.sampleRate)),
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
/// immediately without error when `finishesOnStart`, like a capture the system ended). With a
/// `startGate`, `start()` waits for it to open, like a capture held up by a permission prompt.
final class MockCapture: AudioCapturing {
    private let chunks: [AudioChunk]
    private let streamError: (any Error)?
    private let startError: (any Error)?
    private let finishesOnStart: Bool
    private let startGate: Gate?
    private let stream: AsyncThrowingStream<AudioChunk, any Error>
    private let continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation
    private let startCalls = LockedValue(0)
    private let stopCalls = LockedValue(0)

    init(
        chunks: [AudioChunk] = [],
        streamError: (any Error)? = nil,
        startError: (any Error)? = nil,
        finishesOnStart: Bool = false,
        startGate: Gate? = nil
    ) {
        self.chunks = chunks
        self.streamError = streamError
        self.startError = startError
        self.finishesOnStart = finishesOnStart
        self.startGate = startGate
        let (stream, continuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    var startCount: Int { startCalls.current }
    var stopCount: Int { stopCalls.current }

    func start() async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        startCalls.update { $0 += 1 }
        await startGate?.wait()
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
    let captures: [String: MockCapture]
    let queuedCaptures: LockedValue<[String: [MockCapture]]>

    init(capture: MockCapture, captures: [String: MockCapture] = [:], queuedCaptures: [String: [MockCapture]] = [:]) {
        self.capture = capture
        self.captures = captures
        self.queuedCaptures = LockedValue(queuedCaptures)
    }

    func makeCapture(for device: AudioInputDevice) throws -> any AudioCapturing {
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
    nonisolated let transcribesLive: Bool

    private let transcript: Transcript
    /// Returned instead of `transcript` for a given sample count, to tell sources apart.
    private let transcriptsBySampleCount: [Int: Transcript]
    private let transcribeError: (any Error)?
    /// Thrown instead of returning a transcript for a given sample count, to fail one source.
    private let transcribeErrorsBySampleCount: [Int: any Error]
    private let progressBySampleCount: [Int: Double]
    private let transcriptionGate: Gate?
    private let ungatedSampleCounts: Set<Int>
    private let prepareError: (any Error)?
    private let preparesUntilCancelled: Bool
    private let cancellationGate: Gate?
    private let preparationGate: Gate?
    private let deleteError: (any Error)?
    private let liveSession: MockLiveSession?
    private let liveError: (any Error)?
    private nonisolated let downloaded: LockedValue<Bool>
    private(set) var receivedSampleCounts: [Int] = []
    private(set) var receivedSamples: [[Float]] = []
    /// The `progress` callback of each `transcribe` call, by sample count, to report more later.
    private(set) var progressCallbacks: [Int: @Sendable (Double) -> Void] = [:]
    private(set) var prepareCount = 0
    private(set) var cancelledPrepareCount = 0
    private(set) var deleteCount = 0
    /// Recordings between `recordingWillStart()` and `recordingDidFinish()`.
    nonisolated let recordingsInProgress = LockedValue(0)
    /// `recordingsInProgress` at each `transcribe` call.
    private(set) var recordingsInProgressWhileTranscribing: [Int] = []

    /// - Parameters:
    ///   - isDownloaded: Whether the model starts out on disk. A successful `prepare` downloads it.
    ///   - preparesUntilCancelled: `prepare` stalls halfway, like a slow download, until its task
    ///     is cancelled.
    ///   - cancellationGate: A cancelled `prepare` throws once it opens, like a download that takes a
    ///     while to stop.
    ///   - preparationGate: `prepare` stalls halfway until it opens.
    ///   - deleteError: Thrown by `deleteModel`, which then leaves the model on disk.
    ///   - liveSession: Handed out by `makeLiveSession` for every input; `nil` if the engine
    ///     doesn't transcribe live.
    ///   - liveError: Thrown by `makeLiveSession` instead.
    ///   - progressBySampleCount: Progress `transcribe` reports for a given sample count before
    ///     waiting for `transcriptionGate`.
    ///   - transcriptionGate: `transcribe` returns once it opens.
    ///   - ungatedSampleCounts: Sample counts `transcribe` returns for right away, gate or not.
    init(
        transcript: Transcript = Transcript(segments: []),
        transcriptsBySampleCount: [Int: Transcript] = [:],
        transcribeError: (any Error)? = nil,
        transcribeErrorsBySampleCount: [Int: any Error] = [:],
        progressBySampleCount: [Int: Double] = [:],
        transcriptionGate: Gate? = nil,
        ungatedSampleCounts: Set<Int> = [],
        isDownloaded: Bool = true,
        prepareError: (any Error)? = nil,
        preparesUntilCancelled: Bool = false,
        cancellationGate: Gate? = nil,
        preparationGate: Gate? = nil,
        deleteError: (any Error)? = nil,
        liveSession: MockLiveSession? = nil,
        liveError: (any Error)? = nil
    ) {
        self.transcript = transcript
        self.transcriptsBySampleCount = transcriptsBySampleCount
        self.transcribeError = transcribeError
        self.transcribeErrorsBySampleCount = transcribeErrorsBySampleCount
        self.progressBySampleCount = progressBySampleCount
        self.transcriptionGate = transcriptionGate
        self.ungatedSampleCounts = ungatedSampleCounts
        self.downloaded = LockedValue(isDownloaded)
        self.prepareError = prepareError
        self.preparesUntilCancelled = preparesUntilCancelled
        self.cancellationGate = cancellationGate
        self.preparationGate = preparationGate
        self.deleteError = deleteError
        self.liveSession = liveSession
        self.liveError = liveError
        self.transcribesLive = liveSession != nil || liveError != nil
    }

    func makeLiveSession(options: TranscriptionOptions) async throws -> any LiveTranscriptionSession {
        if let liveError { throw liveError }
        guard let liveSession else { throw TranscriptionError.failed("No live session") }
        return liveSession
    }

    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        prepareCount += 1
        progress?(0.5)
        if preparesUntilCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelledPrepareCount += 1
                await cancellationGate?.wait()
                throw error
            }
        }
        await preparationGate?.wait()
        if let prepareError { throw prepareError }
        downloaded.update { $0 = true }
        progress?(1)
    }

    func deleteModel() async throws {
        deleteCount += 1
        if let deleteError { throw deleteError }
        downloaded.update { $0 = false }
    }

    /// Takes the model off disk behind the coordinator's back, as macOS may with its own models.
    nonisolated func removeModel() {
        downloaded.update { $0 = false }
    }

    nonisolated func recordingWillStart() {
        recordingsInProgress.update { $0 += 1 }
    }

    nonisolated func recordingDidFinish() {
        recordingsInProgress.update { $0 -= 1 }
    }

    func transcribe(
        _ samples: [Float],
        options: TranscriptionOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        receivedSampleCounts.append(samples.count)
        receivedSamples.append(samples)
        progressCallbacks[samples.count] = progress
        recordingsInProgressWhileTranscribing.append(recordingsInProgress.current)
        if let fraction = progressBySampleCount[samples.count] { progress?(fraction) }
        if !ungatedSampleCounts.contains(samples.count) { await transcriptionGate?.wait() }
        try Task.checkCancellation()
        if let error = transcribeErrorsBySampleCount[samples.count] ?? transcribeError { throw error }
        return transcriptsBySampleCount[samples.count] ?? transcript
    }
}

/// Answers each push with the update registered for its sample count, else an empty one.
actor MockLiveSession: LiveTranscriptionSession {
    private let updatesBySampleCount: [Int: LiveTranscriptUpdate]
    private let finishUpdate: LiveTranscriptUpdate
    private let failingSampleCount: Int?
    private let pushError: any Error
    private(set) var pushedSampleCounts: [Int] = []
    private(set) var finishCount = 0

    /// - Parameters:
    ///   - finishUpdate: Returned by `finish`.
    ///   - failingSampleCount: A push of this many samples throws `pushError`, to fail one input.
    init(
        updatesBySampleCount: [Int: LiveTranscriptUpdate] = [:],
        finishUpdate: LiveTranscriptUpdate = LiveTranscriptUpdate(),
        failingSampleCount: Int? = nil,
        pushError: any Error = TranscriptionError.failed("push")
    ) {
        self.updatesBySampleCount = updatesBySampleCount
        self.finishUpdate = finishUpdate
        self.failingSampleCount = failingSampleCount
        self.pushError = pushError
    }

    func push(_ samples: [Float]) async throws -> LiveTranscriptUpdate {
        pushedSampleCounts.append(samples.count)
        if samples.count == failingSampleCount { throw pushError }
        return updatesBySampleCount[samples.count] ?? LiveTranscriptUpdate()
    }

    func finish() async throws -> LiveTranscriptUpdate {
        finishCount += 1
        return finishUpdate
    }
}

/// An engine with a model per language that only knows asynchronously whether it's downloaded,
/// like Apple's speech model.
actor PerLanguageEngine: TranscriptionEngine {
    nonisolated let info = TranscriptionEngineInfo(id: "per-language", displayName: "Per-Language Engine")
    nonisolated var isDownloaded: Bool { checked.current.contains(language.current) }

    /// Languages whose model is on disk; `nil` is the automatic one.
    private nonisolated let installed: LockedValue<Set<String?>>
    /// `installed` as of the last `refreshDownloadStatus()` or `prepare`.
    private nonisolated let checked = LockedValue<Set<String?>>([])
    nonisolated let language = LockedValue<String?>(nil)
    /// `options.language` of each `transcribe` call.
    private(set) var transcribedLanguages: [String?] = []

    init(installed: Set<String?>) {
        self.installed = LockedValue(installed)
    }

    nonisolated func languageDidChange(to language: String?) {
        self.language.update { $0 = language }
    }

    func refreshDownloadStatus() async {
        checked.update { $0 = installed.current }
    }

    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        installed.update { $0.insert(language.current) }
        checked.update { $0 = installed.current }
    }

    func deleteModel() async throws {
        installed.update { $0.remove(language.current) }
        checked.update { $0 = installed.current }
    }

    func transcribe(
        _ samples: [Float],
        options: TranscriptionOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        transcribedLanguages.append(options.language)
        return Transcript(segments: [], language: language.current)
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

/// Fails its first `failures` writes, like a folder on a drive that's asleep, then writes like
/// `InMemoryNoteWriter`.
actor FlakyNoteWriter: NoteWriting {
    struct WriteError: Error {}

    private var failures: Int
    private(set) var notes: [Note] = []

    init(failures: Int) {
        self.failures = failures
    }

    func write(_ note: Note) async throws -> URL {
        if failures > 0 {
            failures -= 1
            throw WriteError()
        }
        notes.append(note)
        return URL(fileURLWithPath: "/tmp/mixdown-flaky-\(notes.count).md")
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

/// Returns `summary`, or throws `error`, and records the transcripts and templates it was given.
final class MockSummarizer: Summarizer {
    let info = SummarizerInfo(id: "mock", displayName: "Mock Summarizer")
    let availability: SummarizerAvailability
    private let summary: NoteSummary
    private let error: (any Error)?
    private let received = LockedValue<[Transcript]>([])
    private let receivedTemplateList = LockedValue<[SummaryTemplate]>([])

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
    var receivedTemplates: [SummaryTemplate] { receivedTemplateList.current }

    func summarize(_ transcript: Transcript, template: SummaryTemplate) async throws -> NoteSummary {
        received.update { $0.append(transcript) }
        receivedTemplateList.update { $0.append(template) }
        if let error { throw error }
        return summary
    }
}

/// Returns `translation`, or throws `error`, and records the transcripts and languages it was given.
final class MockTranslator: Translator {
    let info = TranslatorInfo(id: "mock", displayName: "Mock Translator")
    private let translation: Transcript?
    private let error: (any Error)?
    private let received = LockedValue<[(Transcript, String)]>([])

    init(translation: Transcript? = nil, error: (any Error)? = nil) {
        self.translation = translation
        self.error = error
    }

    var receivedTranscripts: [Transcript] { received.current.map(\.0) }
    var receivedLanguages: [String] { received.current.map(\.1) }

    func translate(_ transcript: Transcript, to target: String) async throws -> Transcript? {
        received.update { $0.append((transcript, target)) }
        if let error { throw error }
        return translation
    }
}

/// Translates each transcript by looking its text up in `translations`, as a live caption's line
/// is translated on its own. Texts it has no translation for are in the target language already;
/// those in `failures` throw their error.
final class DictionaryTranslator: Translator {
    let info = TranslatorInfo(id: "dictionary", displayName: "Dictionary Translator")
    private let translations: [String: String]
    private let failures: [String: any Error]
    private let received = LockedValue<[Transcript]>([])

    init(translations: [String: String] = [:], failures: [String: any Error] = [:]) {
        self.translations = translations
        self.failures = failures
    }

    var receivedTexts: [String] { received.current.map(\.text) }
    var receivedTranscripts: [Transcript] { received.current }

    func translate(_ transcript: Transcript, to target: String) async throws -> Transcript? {
        received.update { $0.append(transcript) }
        if let error = failures[transcript.text] { throw error }
        guard let translation = translations[transcript.text] else { return nil }
        return Transcript(
            segments: transcript.segments.map { TranscriptSegment(start: $0.start, end: $0.end, text: translation) },
            language: target
        )
    }
}
