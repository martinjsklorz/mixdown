import Foundation
import Observation
import os

/// Drives the record → transcribe → write-note flow and exposes its state to the UI.
///
/// All dependencies are protocols, so the coordinator is fully testable with doubles and
/// knows nothing about CoreAudio, ScreenCaptureKit or the speech model.
@MainActor
@Observable
public final class RecordingCoordinator {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Downloading or loading the model. `progress` is 0...1.
        case preparingModel(progress: Double)
        case recording(startedAt: Date)
        case transcribing
        case failed(message: String)
    }

    /// Recordings shorter than this are discarded without transcribing.
    nonisolated static let minimumRecordingDuration: TimeInterval = 0.5

    public private(set) var phase: Phase = .idle
    public private(set) var devices: [AudioInputDevice] = []
    public private(set) var selectedDevice: AudioInputDevice?
    /// Location of the most recently written note.
    public private(set) var lastNoteURL: URL?
    public var noteWriter: any NoteWriting
    public var options: TranscriptionOptions

    public var engineInfo: TranscriptionEngineInfo { engine.info }

    /// Whether the model is on disk. Recording waits for it, since fetching it can take many
    /// minutes; `prepareEngine()` downloads it.
    public private(set) var isModelDownloaded: Bool

    public var isRecording: Bool {
        switch phase {
        case .recording: true
        default: false
        }
    }

    /// Preparing the model or transcribing.
    public var isBusy: Bool {
        switch phase {
        case .preparingModel, .transcribing: true
        default: false
        }
    }

    /// Estimated seconds until the model is ready, while preparing. `nil` until there's enough
    /// progress to extrapolate from (a few seconds in).
    public var preparationTimeRemaining: TimeInterval? {
        guard case .preparingModel = phase else { return nil }
        return preparationEstimator.remaining
    }

    /// Nothing is downloading, recording or transcribing. An error may be showing.
    public var isIdle: Bool {
        guard !isCapturing else { return false }
        switch phase {
        case .idle, .failed: return true
        default: return false
        }
    }

    /// Idle, a device is selected and the model is downloaded.
    public var canStartRecording: Bool {
        isIdle && selectedDevice != nil && isModelDownloaded
    }

    private let deviceProvider: any AudioDeviceProvider
    private let captureFactory: any AudioCaptureFactory
    private let engine: any TranscriptionEngine
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "app.mixdown", category: "coordinator")

    @ObservationIgnored private var preferredDeviceID: String?
    @ObservationIgnored private var session: Session?
    /// The in-flight `engine.prepare` call, kept so `cancelPreparation()` can stop it.
    @ObservationIgnored private var preparation: Task<Void, any Error>?
    /// True while `capture.start()` is in flight; blocks a second start.
    private var isStartingCapture = false
    private var preparationEstimator = RemainingTimeEstimator()

    /// One capture from start to stop.
    private struct Session {
        let id: UUID
        let device: AudioInputDevice
        let capture: any AudioCapturing
        let startedAt: Date
        /// Drains the capture stream off the main actor and returns all samples.
        let consumer: Task<CaptureResult, Never>
    }

    /// Everything a capture stream produced, plus the error that ended it early, if any.
    private struct CaptureResult: Sendable {
        var samples: [Float]
        var error: (any Error)?
    }

    /// - Parameters:
    ///   - preferredDeviceID: Device to select when it's available, e.g. the user's last choice.
    ///   - now: Clock used for recording start times. Injectable for tests.
    public init(
        deviceProvider: any AudioDeviceProvider,
        captureFactory: any AudioCaptureFactory,
        engine: any TranscriptionEngine,
        noteWriter: any NoteWriting,
        options: TranscriptionOptions = .init(),
        preferredDeviceID: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.deviceProvider = deviceProvider
        self.captureFactory = captureFactory
        self.engine = engine
        self.isModelDownloaded = engine.isDownloaded
        self.noteWriter = noteWriter
        self.options = options
        self.preferredDeviceID = preferredDeviceID
        self.now = now
    }

    // MARK: - Devices

    /// Selects the device for the next recording. Ignored while recording.
    public func selectDevice(_ device: AudioInputDevice) {
        guard !isRecording, !isCapturing else { return }
        selectedDevice = device
        preferredDeviceID = device.id
    }

    /// Loads the device list, then follows changes until the calling task is cancelled.
    public func monitorDevices() async {
        // Subscribe first so a change during the initial load isn't missed.
        let updates = deviceProvider.deviceUpdates()
        applyDevices(await deviceProvider.availableDevices())
        for await list in updates {
            applyDevices(list)
        }
    }

    private func applyDevices(_ list: [AudioInputDevice]) {
        devices = list
        reconcileSelection()
    }

    private var isCapturing: Bool { session != nil || isStartingCapture }

    /// Re-resolves the selection against `devices`. Skipped mid-capture so a vanished device
    /// surfaces as a capture error instead of silently switching inputs.
    private func reconcileSelection() {
        guard !isCapturing else { return }
        let resolved = Self.resolveSelection(current: selectedDevice, preferredID: preferredDeviceID, in: devices)
        if resolved != selectedDevice {
            selectedDevice = resolved
        }
    }

    /// Current selection if still present, else the preferred device, else the default
    /// microphone, else the first device.
    nonisolated static func resolveSelection(
        current: AudioInputDevice?,
        preferredID: String?,
        in devices: [AudioInputDevice]
    ) -> AudioInputDevice? {
        if let current, let match = devices.first(where: { $0.id == current.id }) {
            return match
        }
        if let preferredID, let match = devices.first(where: { $0.id == preferredID }) {
            return match
        }
        if let match = devices.first(where: { $0.kind == .microphone && $0.isDefault }) {
            return match
        }
        return devices.first
    }

    // MARK: - Engine

    /// Downloads/loads the model ahead of the first recording, reporting progress via `phase`.
    /// Stopped by `cancelPreparation()` or by cancelling the calling task.
    public func prepareEngine() async {
        guard isIdle else { return }

        preparationEstimator = RemainingTimeEstimator()
        preparationEstimator.add(progress: 0, at: now())
        phase = .preparingModel(progress: 0)
        let preparation = Task { [engine] in
            // Progress arrives on arbitrary threads; hop to the main actor before touching state.
            try await engine.prepare { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.updatePreparationProgress(progress)
                }
            }
        }
        self.preparation = preparation
        let result = await withTaskCancellationHandler {
            await preparation.result
        } onCancel: {
            preparation.cancel()
        }

        // After a cancel, a newer preparation may own `phase` already.
        guard self.preparation == preparation else { return }
        self.preparation = nil
        // Checked on every outcome: a failed or cancelled download may still have finished.
        isModelDownloaded = engine.isDownloaded
        switch result {
        case .success:
            logger.info("Transcription engine ready")
            phase = .idle
        case .failure where preparation.isCancelled:
            logger.info("Preparing engine cancelled")
            phase = .idle
        case .failure(let error):
            logger.error("Preparing engine failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(message: error.localizedDescription)
        }
    }

    /// Stops an in-progress model download. Files already fetched are kept, so the next
    /// `prepareEngine()` (or recording) resumes from them.
    public func cancelPreparation() {
        guard case .preparingModel = phase, let preparation else { return }
        preparation.cancel()
        self.preparation = nil
        isModelDownloaded = engine.isDownloaded
        phase = .idle
    }

    private func updatePreparationProgress(_ progress: Double) {
        guard case .preparingModel = phase, progress.isFinite else { return }
        let clamped = min(max(progress, 0), 1)
        preparationEstimator.add(progress: clamped, at: now())
        phase = .preparingModel(progress: clamped)
    }

    // MARK: - Recording

    public func startRecording() async {
        guard canStartRecording, let device = selectedDevice else { return }
        isStartingCapture = true

        let capture: any AudioCapturing
        let stream: AsyncThrowingStream<AudioChunk, any Error>
        do {
            capture = try captureFactory.makeCapture(for: device)
            stream = try await capture.start()
        } catch {
            logger.error("Starting capture failed: \(error.localizedDescription, privacy: .public)")
            isStartingCapture = false
            phase = .failed(message: error.localizedDescription)
            reconcileSelection()
            return
        }

        let sessionID = UUID()
        let startedAt = now()
        let consumer = Task.detached(priority: .userInitiated) { () async -> CaptureResult in
            var samples: [Float] = []
            do {
                for try await chunk in stream {
                    samples.append(contentsOf: chunk.samples)
                }
            } catch {
                return CaptureResult(samples: samples, error: error)
            }
            return CaptureResult(samples: samples, error: nil)
        }
        session = Session(id: sessionID, device: device, capture: capture, startedAt: startedAt, consumer: consumer)
        isStartingCapture = false
        phase = .recording(startedAt: startedAt)
        logger.info("Recording started on \(device.name, privacy: .public)")

        // The stream can also end without `stopRecording()`: the device disappears, permission is
        // revoked, or the user stops capture from the system's menu bar indicator.
        Task { [weak self] in
            let result = await consumer.value
            await self?.captureDidEnd(sessionID: sessionID, result: result)
        }
    }

    /// Stops capture, transcribes, writes the note and updates `lastNoteURL`.
    public func stopRecording() async {
        guard let session else { return }
        // Clearing the session first makes repeated stops and the end-of-stream handler no-ops.
        self.session = nil

        await session.capture.stop()
        // An error racing a user-initiated stop doesn't matter; keep whatever was captured.
        let result = await session.consumer.value
        await finish(session, samples: result.samples, interruption: nil)
    }

    /// Transcribes and saves a finished capture. If capture ended with `interruption`, the partial
    /// recording is still saved and the error is surfaced afterwards.
    private func finish(_ session: Session, samples: [Float], interruption: (any Error)?) async {
        reconcileSelection()

        let duration = Double(samples.count) / AudioChunk.sampleRate
        guard duration >= Self.minimumRecordingDuration else {
            logger.info("Discarding \(duration, format: .fixed(precision: 2)) s recording as too short")
            phase = interruption.map { Phase.failed(message: $0.localizedDescription) } ?? .idle
            return
        }

        phase = .transcribing
        do {
            let transcript = try await engine.transcribe(samples, options: options)
            let note = Note(
                title: Self.noteTitle(for: session.startedAt),
                createdAt: session.startedAt,
                duration: duration,
                source: session.device,
                engine: engine.info,
                transcript: transcript
            )
            let url = try await noteWriter.write(note)
            lastNoteURL = url
            logger.info("Wrote note to \(url.path(percentEncoded: false), privacy: .private)")
            if let interruption {
                phase = .failed(message: Self.interruptedMessage(for: interruption))
            } else {
                phase = .idle
            }
        } catch {
            logger.error("Finishing recording failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(message: error.localizedDescription)
        }
    }

    public func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    /// Clears a `.failed` phase.
    public func dismissError() {
        if case .failed = phase {
            phase = .idle
        }
    }

    private func captureDidEnd(sessionID: UUID, result: CaptureResult) async {
        // A stop already in progress owns the session.
        guard let session, session.id == sessionID else { return }
        self.session = nil
        if let error = result.error {
            logger.error("Capture failed: \(error.localizedDescription, privacy: .public)")
        } else {
            logger.info("Capture ended by the system")
        }
        await session.capture.stop()
        await finish(session, samples: result.samples, interruption: result.error)
    }

    nonisolated static func interruptedMessage(for error: any Error) -> String {
        "Recording stopped early. \(error.localizedDescription) The audio captured until then was saved."
    }

    nonisolated static func noteTitle(for date: Date) -> String {
        "Recording \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
