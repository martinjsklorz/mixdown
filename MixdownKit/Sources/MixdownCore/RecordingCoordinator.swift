import Foundation
import Observation
import os

/// Drives the record → transcribe → write-note flow and exposes its state to the UI.
///
/// Several inputs can be recorded at once, e.g. the microphone for the user and system audio for
/// the other people on a call. Each is captured into its own track, lined up on the host clock,
/// transcribed separately and labeled by `sourceLabels`; the transcripts are then merged by time.
/// A single input is transcribed as before, without labels.
///
/// All dependencies are protocols, so the coordinator is fully testable with doubles and
/// knows nothing about CoreAudio or the speech model.
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
    /// Inputs the next recording captures, in `devices` order.
    public private(set) var selectedDevices: [AudioInputDevice] = []
    /// Location of the most recently written note.
    public private(set) var lastNoteURL: URL?
    public var noteWriter: any NoteWriting
    public var options: TranscriptionOptions
    /// Speaker names for multi-source recordings.
    public var sourceLabels: SourceLabels

    public var engineInfo: TranscriptionEngineInfo { engine.info }

    /// Whether the model is on disk. Recording waits for it, since fetching it can take many
    /// minutes; `prepareEngine()` downloads it.
    public private(set) var isModelDownloaded: Bool

    /// True while `deleteModel()` removes the model's files.
    public private(set) var isDeletingModel = false

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

    /// Nothing is downloading, deleting, recording or transcribing. An error may be showing.
    public var isIdle: Bool {
        guard !isCapturing, !isDeletingModel else { return false }
        switch phase {
        case .idle, .failed: return true
        default: return false
        }
    }

    /// Idle, at least one device is selected and the model is downloaded.
    public var canStartRecording: Bool {
        isIdle && !selectedDevices.isEmpty && isModelDownloaded
    }

    private let deviceProvider: any AudioDeviceProvider
    private let captureFactory: any AudioCaptureFactory
    private let engine: any TranscriptionEngine
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "app.mixdown", category: "coordinator")

    @ObservationIgnored private var preferredDeviceIDs: [String]
    @ObservationIgnored private var session: Session?
    /// The in-flight `engine.prepare` call, kept so `cancelPreparation()` can stop it.
    @ObservationIgnored private var preparation: Task<Void, any Error>?
    /// True while the captures are starting; blocks a second start.
    private var isStartingCapture = false
    private var preparationEstimator = RemainingTimeEstimator()

    /// One recording from start to stop, across all of its sources.
    private struct Session {
        let id: UUID
        let sources: [Source]
        let startedAt: Date

        var devices: [AudioInputDevice] { sources.map(\.device) }
    }

    /// One input of a session.
    private struct Source: Sendable {
        let device: AudioInputDevice
        let capture: any AudioCapturing
        /// Drains the capture stream off the main actor and returns the track.
        let consumer: Task<CaptureResult, Never>
    }

    /// Everything a capture stream produced, plus the error that ended it early, if any.
    private struct CaptureResult: Sendable {
        var track: AudioTrack
        var error: (any Error)?
    }

    /// A finished source's audio, positioned on the recording's timeline.
    private struct RecordedTrack: Sendable {
        let device: AudioInputDevice
        let samples: [Float]
        /// Seconds from the start of the recording to the track's first sample.
        let offset: TimeInterval

        var end: TimeInterval { offset + Double(samples.count) / AudioChunk.sampleRate }
    }

    /// - Parameters:
    ///   - preferredDeviceIDs: Devices to select when they're available, e.g. the user's last choice.
    ///   - now: Clock used for recording start times. Injectable for tests.
    public init(
        deviceProvider: any AudioDeviceProvider,
        captureFactory: any AudioCaptureFactory,
        engine: any TranscriptionEngine,
        noteWriter: any NoteWriting,
        options: TranscriptionOptions = .init(),
        sourceLabels: SourceLabels = .init(),
        preferredDeviceIDs: [String] = [],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.deviceProvider = deviceProvider
        self.captureFactory = captureFactory
        self.engine = engine
        self.isModelDownloaded = engine.isDownloaded
        self.noteWriter = noteWriter
        self.options = options
        self.sourceLabels = sourceLabels
        self.preferredDeviceIDs = preferredDeviceIDs
        self.now = now
    }

    // MARK: - Devices

    /// Selects the devices for the next recording and remembers them as preferred. Ignored while
    /// recording, and for an empty list. Returns whether the selection was applied.
    @discardableResult
    public func selectDevices(_ selection: [AudioInputDevice]) -> Bool {
        guard !isRecording, !isCapturing, !selection.isEmpty else { return false }
        preferredDeviceIDs = selection.map(\.id)
        // Devices that vanished since the menu was drawn are resolved like any other missing one.
        selectedDevices = Self.resolveSelection(preferredIDs: preferredDeviceIDs, in: devices)
        return true
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
        let resolved = Self.resolveSelection(preferredIDs: preferredDeviceIDs, in: devices)
        if resolved != selectedDevices {
            selectedDevices = resolved
        }
    }

    /// The preferred devices that are present. A preferred microphone that's missing is replaced by
    /// the default microphone, so unplugging a headset doesn't silently drop the user's voice. With
    /// nothing preferred or available, the default microphone, else the first device.
    nonisolated static func resolveSelection(
        preferredIDs: [String],
        in devices: [AudioInputDevice]
    ) -> [AudioInputDevice] {
        let defaultMicrophone =
            devices.first { $0.kind == .microphone && $0.isDefault }
            ?? devices.first { $0.kind == .microphone }

        var ids = Set<String>()
        for id in preferredIDs {
            if devices.contains(where: { $0.id == id }) {
                ids.insert(id)
            } else if id != AudioInputDevice.systemAudioID, let defaultMicrophone {
                ids.insert(defaultMicrophone.id)
            }
        }
        if ids.isEmpty, let fallback = defaultMicrophone ?? devices.first {
            ids.insert(fallback.id)
        }
        return devices.filter { ids.contains($0.id) }
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

    /// Deletes the downloaded model to free disk space. Recording is unavailable until it's
    /// downloaded again. Ignored unless idle with the model on disk.
    public func deleteModel() async {
        guard isIdle, isModelDownloaded else { return }
        isDeletingModel = true
        do {
            try await engine.deleteModel()
            logger.info("Deleted transcription model")
            phase = .idle
        } catch {
            logger.error("Deleting model failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(message: error.localizedDescription)
        }
        // Checked either way: a failed delete may have removed some files.
        isModelDownloaded = engine.isDownloaded
        isDeletingModel = false
    }

    private func updatePreparationProgress(_ progress: Double) {
        guard case .preparingModel = phase, progress.isFinite else { return }
        let clamped = min(max(progress, 0), 1)
        preparationEstimator.add(progress: clamped, at: now())
        phase = .preparingModel(progress: clamped)
    }

    // MARK: - Recording

    public func startRecording() async {
        guard canStartRecording else { return }
        let devices = selectedDevices
        isStartingCapture = true

        let startedCaptures: [StartedCapture]
        do {
            startedCaptures = try await startCaptures(for: devices)
        } catch {
            logger.error("Starting capture failed: \(error.localizedDescription, privacy: .public)")
            isStartingCapture = false
            phase = .failed(message: error.localizedDescription)
            reconcileSelection()
            return
        }

        let sessionID = UUID()
        let startedAt = now()
        let sources = startedCaptures.map { started -> Source in
            let stream = started.stream
            let consumer = Task.detached(priority: .userInitiated) { () async -> CaptureResult in
                var track = AudioTrack()
                do {
                    for try await chunk in stream {
                        track.append(chunk)
                    }
                } catch {
                    return CaptureResult(track: track, error: error)
                }
                return CaptureResult(track: track, error: nil)
            }
            return Source(device: started.device, capture: started.capture, consumer: consumer)
        }
        session = Session(id: sessionID, sources: sources, startedAt: startedAt)
        isStartingCapture = false
        phase = .recording(startedAt: startedAt)
        let names = devices.map(\.name).joined(separator: " + ")
        logger.info("Recording started on \(names, privacy: .public)")

        // A stream can also end without `stopRecording()`: the device disappears, permission is
        // revoked, or the user stops capture from the system's menu bar indicator. Any source
        // ending ends the whole recording.
        for source in sources {
            let consumer = source.consumer
            Task { [weak self] in
                _ = await consumer.value
                await self?.captureDidEnd(sessionID: sessionID)
            }
        }
    }

    private typealias CaptureStream = AsyncThrowingStream<AudioChunk, any Error>

    private struct StartedCapture {
        let device: AudioInputDevice
        let capture: any AudioCapturing
        let stream: CaptureStream
    }

    /// Starts one capture per device, all at once so they begin as close together as possible.
    /// If any fails, the others are stopped again and the first device's error is thrown.
    private func startCaptures(for devices: [AudioInputDevice]) async throws -> [StartedCapture] {
        let captures = try devices.map { try captureFactory.makeCapture(for: $0) }
        let results = await withTaskGroup(
            of: (Int, Result<CaptureStream, any Error>).self,
            returning: [Result<CaptureStream, any Error>].self
        ) { group in
            for (index, capture) in captures.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await capture.start()))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var results = [Result<CaptureStream, any Error>?](repeating: nil, count: captures.count)
            for await (index, result) in group {
                results[index] = result
            }
            return results.compactMap { $0 }
        }

        var started: [StartedCapture] = []
        var firstError: (any Error)?
        for (index, result) in results.enumerated() {
            switch result {
            case .success(let stream):
                started.append(StartedCapture(device: devices[index], capture: captures[index], stream: stream))
            case .failure(let error): firstError = firstError ?? error
            }
        }
        if let firstError {
            for capture in started.map(\.capture) {
                await capture.stop()
            }
            throw firstError
        }
        return started
    }

    /// Stops capture, transcribes, writes the note and updates `lastNoteURL`.
    public func stopRecording() async {
        guard let session else { return }
        // Clearing the session first makes repeated stops and the end-of-stream handlers no-ops.
        self.session = nil

        // An error racing a user-initiated stop doesn't matter; keep whatever was captured.
        let results = await endCaptures(of: session)
        await finish(session, results: results, interruption: nil)
    }

    /// Stops every capture of `session` and collects what each one recorded.
    private func endCaptures(of session: Session) async -> [CaptureResult] {
        await withTaskGroup(of: Void.self) { group in
            for capture in session.sources.map(\.capture) {
                group.addTask { await capture.stop() }
            }
        }
        var results: [CaptureResult] = []
        for source in session.sources {
            results.append(await source.consumer.value)
        }
        return results
    }

    /// Transcribes and saves a finished recording. If capture ended with `interruption`, the
    /// partial recording is still saved and the error is surfaced afterwards.
    private func finish(_ session: Session, results: [CaptureResult], interruption: (any Error)?) async {
        reconcileSelection()

        let offsets = AudioTrack.startOffsets(of: results.map(\.track))
        let tracks = session.sources.indices.map { index in
            RecordedTrack(
                device: session.sources[index].device,
                samples: results[index].track.samples,
                offset: offsets[index]
            )
        }
        let duration = tracks.map(\.end).max() ?? 0
        guard duration >= Self.minimumRecordingDuration else {
            logger.info("Discarding \(duration, format: .fixed(precision: 2)) s recording as too short")
            phase = interruption.map { Phase.failed(message: $0.localizedDescription) } ?? .idle
            return
        }

        phase = .transcribing
        do {
            let transcript: Transcript
            if let track = tracks.first, tracks.count == 1 {
                transcript = try await engine.transcribe(track.samples, options: options)
            } else {
                transcript = try await transcribeSeparately(tracks, devices: session.devices)
            }
            let note = Note(
                title: Self.noteTitle(for: session.startedAt),
                createdAt: session.startedAt,
                duration: duration,
                sources: session.devices,
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

    /// Transcribes each track on its own, so speech stays attributed to its source, then merges the
    /// labeled transcripts by time. Tracks are submitted together; the engine decides how many it
    /// runs at once (speech-swift runs one at a time, since they share the GPU anyway).
    private func transcribeSeparately(_ tracks: [RecordedTrack], devices: [AudioInputDevice]) async throws -> Transcript
    {
        let engine = engine
        let options = options
        let sourceLabels = sourceLabels
        let audible = tracks.filter {
            Double($0.samples.count) / AudioChunk.sampleRate >= Self.minimumRecordingDuration
        }
        for track in tracks {
            let duration = Double(track.samples.count) / AudioChunk.sampleRate
            logger.info(
                "Track \(track.device.name, privacy: .public): \(duration, format: .fixed(precision: 1)) s starting at \(track.offset, format: .fixed(precision: 2)) s"
            )
        }

        let transcripts = try await withThrowingTaskGroup(
            of: (Int, Transcript).self,
            returning: [Transcript].self
        ) { group in
            for (index, track) in audible.enumerated() {
                group.addTask {
                    var transcript = try await engine.transcribe(track.samples, options: options)
                    for i in transcript.segments.indices {
                        transcript.segments[i].start += track.offset
                        transcript.segments[i].end += track.offset
                    }
                    return (index, transcript)
                }
            }
            var transcripts = [Transcript?](repeating: nil, count: audible.count)
            for try await (index, transcript) in group {
                transcripts[index] = transcript
            }
            return transcripts.compactMap { $0 }
        }

        let sources = zip(audible, transcripts).map { track, transcript in
            SourceTranscript(
                device: track.device,
                label: sourceLabels.label(for: track.device, among: devices),
                transcript: transcript
            )
        }
        return TranscriptMerger.merge(sources)
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

    private func captureDidEnd(sessionID: UUID) async {
        // A stop already in progress owns the session.
        guard let session, session.id == sessionID else { return }
        self.session = nil

        let results = await endCaptures(of: session)
        let error = results.lazy.compactMap(\.error).first
        if let error {
            logger.error("Capture failed: \(error.localizedDescription, privacy: .public)")
        } else {
            logger.info("Capture ended by the system")
        }
        await finish(session, results: results, interruption: error)
    }

    nonisolated static func interruptedMessage(for error: any Error) -> String {
        "Recording stopped early. \(error.localizedDescription) The audio captured until then was saved."
    }

    nonisolated static func noteTitle(for date: Date) -> String {
        "Recording \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
