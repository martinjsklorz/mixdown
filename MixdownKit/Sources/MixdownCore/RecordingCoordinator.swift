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
/// Inputs can change while recording. A microphone that goes away, such as AirPods being taken
/// out, is replaced by the default microphone, and the user can switch microphones or turn
/// system audio on and off. Each kind of input keeps one track, whichever device it came from.
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
        /// `progress` is 0...1 across all of the recording's sources.
        case transcribing(progress: Double)
        /// Summarizing the transcript before the note is saved.
        case summarizing
        case failed(message: String)
    }

    /// Recordings shorter than this are discarded without transcribing.
    nonisolated static let minimumRecordingDuration: TimeInterval = 0.5

    public private(set) var phase: Phase = .idle {
        didSet { modelError = nil }
    }
    /// The message of a `.failed` phase caused by the model failing to download, load or delete,
    /// as opposed to e.g. a capture error. `nil` once the phase changes.
    public private(set) var modelError: String?
    public private(set) var devices: [AudioInputDevice] = []
    /// Inputs the running recording captures, or the next one will, in `devices` order.
    public private(set) var selectedDevices: [AudioInputDevice] = []
    /// Location of the most recently written note.
    public private(set) var lastNoteURL: URL?
    /// Saves finished notes. `nil` while there's no folder to save to; recording waits for one.
    public var noteWriter: (any NoteWriting)?
    /// Adds a summary to each note. `nil` while summaries are off.
    public var summarizer: (any Summarizer)?
    public var options: TranscriptionOptions
    /// Speaker names for multi-source recordings.
    public var sourceLabels: SourceLabels

    /// Each source's level while recording, by device ID. Changes about ten times a second, so
    /// only read it from views that draw meters.
    public private(set) var inputLevels: [String: InputLevel] = [:]

    /// Sources of the current recording that haven't made a sound since it started, once
    /// `silenceWarningDelay` has passed. A source leaves the list as soon as it's heard.
    ///
    /// Without the System Audio Recording permission the tap keeps running but delivers silence,
    /// so this is the only way a denial shows up before the note comes out empty. As the tap is
    /// just as silent when nothing plays, system audio only counts as silent while another app
    /// plays audio, if there's a `playbackMonitor` to tell.
    public private(set) var silentDevices: [AudioInputDevice] = []

    /// How long a source may stay silent before it's listed in `silentDevices`. For system audio,
    /// the time other apps play audio.
    var silenceWarningDelay: Duration = .seconds(10)

    /// How long to wait after a device goes away mid-recording before picking its replacement,
    /// so the system has made another device the default by then.
    var deviceSwitchDelay: Duration = .milliseconds(500)

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

    /// Preparing the model, transcribing or summarizing.
    public var isBusy: Bool {
        switch phase {
        case .preparingModel, .transcribing, .summarizing: true
        default: false
        }
    }

    /// Estimated seconds until the model is ready or the note is transcribed, while preparing or
    /// transcribing. `nil` until there's enough progress to extrapolate from (a few seconds in).
    public var timeRemaining: TimeInterval? {
        switch phase {
        case .preparingModel, .transcribing: return progressEstimator.remaining
        default: return nil
        }
    }

    /// Nothing is downloading, deleting, recording, transcribing or summarizing. An error may be
    /// showing.
    public var isIdle: Bool {
        guard !isCapturing, !isDeletingModel else { return false }
        switch phase {
        case .idle, .failed: return true
        default: return false
        }
    }

    /// Idle, at least one device is selected, the model is downloaded and there's a `noteWriter`.
    public var canStartRecording: Bool {
        isIdle && !selectedDevices.isEmpty && isModelDownloaded && noteWriter != nil
    }

    private let deviceProvider: any AudioDeviceProvider
    private let captureFactory: any AudioCaptureFactory
    private let engine: any TranscriptionEngine
    private let playbackMonitor: (any AudioPlaybackMonitoring)?
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "app.mixdown", category: "coordinator")

    /// The user's choice of inputs, by ID. May hold `AudioInputDevice.defaultMicrophoneID` and
    /// devices that aren't connected; `selectedDevices` is what that resolves to.
    public private(set) var preferredDeviceIDs: [String]

    /// Whether the microphone follows the system's default input: chosen explicitly, or nothing
    /// was ever chosen.
    public var followsDefaultMicrophone: Bool {
        preferredDeviceIDs.isEmpty || preferredDeviceIDs.contains(AudioInputDevice.defaultMicrophoneID)
    }
    @ObservationIgnored private var session: Session?
    /// The in-flight `engine.prepare` call, kept so `cancelPreparation()` can stop it.
    @ObservationIgnored private var preparation: Task<Void, any Error>?
    /// True while the captures are starting; blocks a second start.
    private var isStartingCapture = false
    /// Sources of the current recording that delivered sound at least once.
    @ObservationIgnored private var heardDeviceIDs: Set<String> = []
    /// Add each recording device to `silentDevices` once `silenceWarningDelay` has passed, by ID.
    @ObservationIgnored private var silenceChecks: [String: Task<Void, Never>] = [:]
    /// Fed by whichever of preparing and transcribing is running.
    private var progressEstimator = RemainingTimeEstimator()
    /// Per-track progress of the transcription in flight.
    @ObservationIgnored private var transcriptionProgress: TranscriptionProgress?

    /// One recording from start to stop, across all of its inputs. A class, as its inputs change
    /// while it runs.
    @MainActor
    private final class Session {
        let id = UUID()
        let startedAt: Date
        /// Whether the recording was started for a call, from a notification or automatically.
        var isCall = false
        private(set) var lanes: [Lane] = []
        /// Devices that went away or failed to start during this recording. They aren't picked
        /// again until they leave the device list or the user chooses them.
        var unavailableDeviceIDs: Set<String> = []
        /// Why an input last stopped on its own; reported if no input is left.
        var lastCaptureError: (any Error)?
        /// Whether `syncCaptures(of:)` is running, and whether it should go around once more.
        var isSyncing = false
        var needsSync = false
        /// Inputs whose device went away and that are waiting for the system to pick a new
        /// default. The recording doesn't end for lack of inputs while there are any.
        var pendingReplacements = 0

        init(startedAt: Date) {
            self.startedAt = startedAt
        }

        /// The devices recording right now.
        var activeDevices: [AudioInputDevice] { lanes.compactMap(\.current?.device) }

        /// Every device recorded from, in the order they were first used.
        var devices: [AudioInputDevice] {
            var seen = Set<String>()
            return lanes.flatMap { $0.captures.map(\.device) }.filter { seen.insert($0.id).inserted }
        }

        func addLane(kind: AudioSourceKind) -> Lane {
            let lane = Lane(kind: kind)
            lanes.append(lane)
            return lane
        }
    }

    /// One input of a session, such as "the microphone", recorded into a single track. Its device
    /// can change mid-recording; each device it used has a capture of its own.
    @MainActor
    private final class Lane {
        let kind: AudioSourceKind
        /// Every capture of the lane, the current one last.
        private(set) var captures: [Capture] = []
        /// The capture recording right now. `nil` while switching devices, after the device went
        /// away, or once the input is turned off.
        var current: Capture?

        init(kind: AudioSourceKind) {
            self.kind = kind
        }

        /// The device the lane started with, which names it in the transcript.
        var firstDevice: AudioInputDevice? { captures.first?.device }

        func add(_ capture: Capture) {
            captures.append(capture)
            current = capture
        }
    }

    /// One capture of a device, from start to stop.
    private struct Capture: Sendable {
        let id = UUID()
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

    /// A finished lane's audio, positioned on the recording's timeline.
    private struct RecordedTrack: Sendable {
        let device: AudioInputDevice
        let samples: [Float]
        /// Seconds from the start of the recording to the track's first sample.
        let offset: TimeInterval

        var end: TimeInterval { offset + Double(samples.count) / AudioChunk.sampleRate }
    }

    /// Combines the progress of a recording's tracks, each weighted by its length. speech-swift
    /// transcribes them one after another, so the total keeps moving at about the same pace.
    private struct TranscriptionProgress {
        let sessionID: UUID
        let sampleCounts: [Int]
        var fractions: [Double]

        init(sessionID: UUID, tracks: [RecordedTrack]) {
            self.sessionID = sessionID
            sampleCounts = tracks.map(\.samples.count)
            fractions = Array(repeating: 0, count: tracks.count)
        }

        var total: Double {
            let samples = Double(sampleCounts.reduce(0, +))
            guard samples > 0 else { return 0 }
            return zip(sampleCounts, fractions).reduce(0) { $0 + Double($1.0) * $1.1 } / samples
        }
    }

    /// - Parameters:
    ///   - preferredDeviceIDs: Devices to select when they're available, e.g. the user's last choice.
    ///   - playbackMonitor: Tells silent system audio with nothing playing from a missing permission.
    ///     Without one, system audio is flagged like a microphone.
    ///   - now: Clock used for recording start times. Injectable for tests.
    public init(
        deviceProvider: any AudioDeviceProvider,
        captureFactory: any AudioCaptureFactory,
        engine: any TranscriptionEngine,
        noteWriter: (any NoteWriting)?,
        summarizer: (any Summarizer)? = nil,
        options: TranscriptionOptions = .init(),
        sourceLabels: SourceLabels = .init(),
        preferredDeviceIDs: [String] = [],
        playbackMonitor: (any AudioPlaybackMonitoring)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.deviceProvider = deviceProvider
        self.captureFactory = captureFactory
        self.engine = engine
        self.isModelDownloaded = engine.isDownloaded
        self.noteWriter = noteWriter
        self.summarizer = summarizer
        self.options = options
        self.sourceLabels = sourceLabels
        self.preferredDeviceIDs = preferredDeviceIDs
        self.playbackMonitor = playbackMonitor
        self.now = now
    }

    // MARK: - Devices

    /// Selects the devices to record and remembers them as preferred. While recording, the
    /// recording switches to them. Ignored while the recording starts, and for an empty list.
    /// Returns whether the selection was applied.
    @discardableResult
    public func selectDevices(_ selection: [AudioInputDevice]) -> Bool {
        guard !isStartingCapture, !selection.isEmpty else { return false }
        preferredDeviceIDs = selection.map(\.id)
        // Choosing a device that went away mid-recording tries it again.
        session?.unavailableDeviceIDs.subtract(preferredDeviceIDs)
        // Devices that vanished since the menu was drawn are resolved like any other missing one.
        reconcileSelection()
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
        // A device that went away and comes back may be recorded from again.
        session?.unavailableDeviceIDs.formIntersection(list.map(\.id))
        reconcileSelection()
    }

    private var isCapturing: Bool { session != nil || isStartingCapture }

    /// Re-resolves the selection against `devices` and, while recording, switches the recording
    /// to it. That's how a recording follows a microphone being unplugged or plugged back in.
    private func reconcileSelection() {
        guard !isStartingCapture else { return }
        guard let session else {
            let resolved = Self.resolveSelection(preferredIDs: preferredDeviceIDs, in: devices)
            if resolved != selectedDevices {
                selectedDevices = resolved
            }
            return
        }

        let available = devices.filter { !session.unavailableDeviceIDs.contains($0.id) }
        let resolved = Self.resolveSelection(
            preferredIDs: preferredDeviceIDs,
            in: available,
            fallsBackToAnyDevice: false
        )
        // With nothing left to switch to, the recording ends once its last input does.
        if !resolved.isEmpty, resolved != selectedDevices {
            selectedDevices = resolved
        }
        guard Set(selectedDevices.map(\.id)) != Set(session.activeDevices.map(\.id)) else { return }
        if session.isSyncing {
            // Set right away, so the running sync can't decide that no input is left first.
            session.needsSync = true
        } else {
            Task { await syncCaptures(of: session) }
        }
    }

    /// The preferred devices that are present. `AudioInputDevice.defaultMicrophone` stands for the
    /// default microphone. A preferred microphone that's missing is replaced by the default
    /// microphone too, so unplugging a headset doesn't silently drop the user's voice. With
    /// nothing preferred or available, the default microphone, else the first device unless
    /// `fallsBackToAnyDevice` is off. A recording doesn't start capturing system audio on its own.
    nonisolated static func resolveSelection(
        preferredIDs: [String],
        in devices: [AudioInputDevice],
        fallsBackToAnyDevice: Bool = true
    ) -> [AudioInputDevice] {
        let defaultMicrophone =
            devices.first { $0.kind == .microphone && $0.isDefault }
            ?? devices.first { $0.kind == .microphone }

        var ids = Set<String>()
        for id in preferredIDs {
            if id == AudioInputDevice.defaultMicrophoneID {
                if let defaultMicrophone { ids.insert(defaultMicrophone.id) }
            } else if devices.contains(where: { $0.id == id }) {
                ids.insert(id)
            } else if id != AudioInputDevice.systemAudioID, let defaultMicrophone {
                ids.insert(defaultMicrophone.id)
            }
        }
        if ids.isEmpty, let fallback = defaultMicrophone ?? (fallsBackToAnyDevice ? devices.first : nil) {
            ids.insert(fallback.id)
        }
        return devices.filter { ids.contains($0.id) }
    }

    // MARK: - Engine

    /// Downloads/loads the model ahead of the first recording, reporting progress via `phase`.
    /// Stopped by `cancelPreparation()` or by cancelling the calling task.
    public func prepareEngine() async {
        guard isIdle else { return }

        progressEstimator = RemainingTimeEstimator()
        progressEstimator.add(progress: 0, at: now())
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
            failWithModelError(error)
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
            failWithModelError(error)
        }
        // Checked either way: a failed delete may have removed some files.
        isModelDownloaded = engine.isDownloaded
        isDeletingModel = false
    }

    private func failWithModelError(_ error: any Error) {
        phase = .failed(message: error.localizedDescription)
        modelError = error.localizedDescription
    }

    private func updatePreparationProgress(_ progress: Double) {
        guard case .preparingModel = phase, progress.isFinite else { return }
        let clamped = min(max(progress, 0), 1)
        progressEstimator.add(progress: clamped, at: now())
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

        let session = Session(startedAt: now())
        self.session = session
        isStartingCapture = false
        for started in startedCaptures {
            attach(started, to: session.addLane(kind: started.device.kind), in: session)
        }
        phase = .recording(startedAt: session.startedAt)
        let names = devices.map(\.name).joined(separator: " + ")
        logger.info("Recording started on \(names, privacy: .public)")
        // Catches devices that changed while the captures were starting.
        reconcileSelection()
    }

    /// Makes `started` the lane's current capture: drains its stream into a track, watches for it
    /// ending on its own, and checks that it isn't silent.
    private func attach(_ started: StartedCapture, to lane: Lane, in session: Session) {
        let stream = started.stream
        let deviceID = started.device.id
        let sessionID = session.id
        let consumer = Task.detached(priority: .userInitiated) { [weak self] () async -> CaptureResult in
            var track = AudioTrack()
            var meter = LevelMeter()
            do {
                for try await chunk in stream {
                    track.append(chunk)
                    // Fire and forget, so a busy main actor never holds up capture.
                    if let level = meter.add(chunk) {
                        Task { @MainActor [weak self] in
                            self?.updateLevel(level, of: deviceID, sessionID: sessionID)
                        }
                    }
                }
            } catch {
                return CaptureResult(track: track, error: error)
            }
            return CaptureResult(track: track, error: nil)
        }
        let capture = Capture(device: started.device, capture: started.capture, consumer: consumer)
        lane.add(capture)
        Task { [weak self] in
            let result = await consumer.value
            await self?.captureDidEnd(capture, of: lane, in: session, result: result)
        }
        scheduleSilenceCheck(of: started.device, in: session)
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
        // An error racing a user-initiated stop doesn't matter; keep whatever was captured.
        guard let session else { return }
        await end(session, interruption: nil)
    }

    /// Stops every capture of `session`, then transcribes and saves what they recorded. If capture
    /// ended with `interruption`, a note of the partial recording is still saved and the error is
    /// surfaced afterwards.
    private func end(_ session: Session, interruption: (any Error)?) async {
        guard self.session === session else { return }
        // Clearing the session first makes repeated stops and the end-of-stream handlers no-ops.
        self.session = nil
        resetLevels()
        let tracks = await endCaptures(of: session)
        await finish(session, tracks: tracks, interruption: interruption)
    }

    /// Stops every capture of `session` and joins what each lane recorded into one track per lane.
    private func endCaptures(of session: Session) async -> [AudioTrack] {
        let running = session.lanes.compactMap(\.current)
        for lane in session.lanes {
            lane.current = nil
        }
        await withTaskGroup(of: Void.self) { group in
            for capture in running.map(\.capture) {
                group.addTask { await capture.stop() }
            }
        }
        var tracks: [AudioTrack] = []
        for lane in session.lanes {
            var track = AudioTrack()
            for capture in lane.captures {
                track.append(await capture.consumer.value.track)
            }
            tracks.append(track)
        }
        return tracks
    }

    /// Transcribes and saves a finished recording, one track per lane of `session`.
    private func finish(_ session: Session, tracks laneTracks: [AudioTrack], interruption: (any Error)?) async {
        reconcileSelection()

        let offsets = AudioTrack.startOffsets(of: laneTracks)
        let tracks = zip(session.lanes, laneTracks).enumerated().compactMap { index, pair -> RecordedTrack? in
            guard let device = pair.0.firstDevice else { return nil }
            return RecordedTrack(device: device, samples: pair.1.samples, offset: offsets[index])
        }
        let duration = tracks.map(\.end).max() ?? 0
        guard duration >= Self.minimumRecordingDuration else {
            logger.info("Discarding \(duration, format: .fixed(precision: 2)) s recording as too short")
            phase = interruption.map { Phase.failed(message: $0.localizedDescription) } ?? .idle
            return
        }

        progressEstimator = RemainingTimeEstimator()
        progressEstimator.add(progress: 0, at: now())
        phase = .transcribing(progress: 0)
        do {
            let transcript: Transcript
            if let track = tracks.first, tracks.count == 1 {
                transcriptionProgress = TranscriptionProgress(sessionID: session.id, tracks: tracks)
                transcript = try await engine.transcribe(
                    track.samples,
                    options: options,
                    progress: progressHandler(track: 0, sessionID: session.id)
                )
            } else {
                transcript = try await transcribeSeparately(tracks, session: session)
            }
            let summary = await summarize(transcript)
            let note = Note(
                title: NoteTitle.make(
                    for: session.startedAt,
                    summaryTitle: summary?.title,
                    isCall: session.isCall,
                    language: summary?.language ?? transcript.language
                ),
                createdAt: session.startedAt,
                duration: duration,
                sources: session.devices,
                engine: engine.info,
                transcript: transcript,
                summary: summary
            )
            // The folder can go away mid-recording, e.g. when its drive is disconnected.
            guard let noteWriter else { throw NoteWritingError.noFolder }
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
            if case TranscriptionError.modelUnavailable = error {
                failWithModelError(error)
            } else {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    /// The transcript's summary, or `nil` if there's no summarizer, it isn't available or it
    /// fails. The note is saved either way, so a failure is only logged.
    private func summarize(_ transcript: Transcript) async -> NoteSummary? {
        guard let summarizer, !transcript.isEmpty else { return nil }
        let name = summarizer.info.displayName
        if case .unavailable(let reason) = summarizer.availability {
            logger.info("Not summarizing, \(name, privacy: .public) is unavailable: \(reason, privacy: .public)")
            return nil
        }
        phase = .summarizing
        do {
            let summary = try await summarizer.summarize(transcript)
            return summary.isEmpty ? nil : summary
        } catch {
            logger.error(
                "Summarizing with \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Transcribes each track on its own, so speech stays attributed to its source, then merges the
    /// labeled transcripts by time. Tracks are submitted together; the engine decides how many it
    /// runs at once (speech-swift runs one at a time, since they share the GPU anyway).
    private func transcribeSeparately(_ tracks: [RecordedTrack], session: Session) async throws -> Transcript {
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

        transcriptionProgress = TranscriptionProgress(sessionID: session.id, tracks: audible)
        let transcripts = try await withThrowingTaskGroup(
            of: (Int, Transcript).self,
            returning: [Transcript].self
        ) { group in
            for (index, track) in audible.enumerated() {
                let progress = progressHandler(track: index, sessionID: session.id)
                group.addTask {
                    var transcript = try await engine.transcribe(track.samples, options: options, progress: progress)
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
                label: sourceLabels.label(for: track.device, among: tracks.map(\.device)),
                transcript: transcript
            )
        }
        return TranscriptMerger.merge(sources)
    }

    /// Forwards one track's progress to `updateTranscriptionProgress` from any thread.
    private func progressHandler(track index: Int, sessionID: UUID) -> @Sendable (Double) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.updateTranscriptionProgress(progress, track: index, sessionID: sessionID)
            }
        }
    }

    private func updateTranscriptionProgress(_ progress: Double, track index: Int, sessionID: UUID) {
        // Updates still in flight when the transcription ends are dropped.
        guard case .transcribing = phase, var transcriptionProgress, transcriptionProgress.sessionID == sessionID,
            transcriptionProgress.fractions.indices.contains(index), progress.isFinite
        else { return }
        transcriptionProgress.fractions[index] = max(transcriptionProgress.fractions[index], min(max(progress, 0), 1))
        self.transcriptionProgress = transcriptionProgress
        let total = transcriptionProgress.total
        progressEstimator.add(progress: total, at: now())
        phase = .transcribing(progress: total)
    }

    /// Marks the recording in progress as a call, so its note is titled as one, e.g. "Call about …".
    /// Ignored when not recording.
    public func markRecordingAsCall() {
        session?.isCall = true
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

    // MARK: - Switching inputs

    /// Handles a capture that ended without being stopped. A device that went away is replaced by
    /// the default microphone; anything else ends the whole recording: permission was revoked, or
    /// the user stopped capture from the system's menu bar indicator.
    private func captureDidEnd(_ capture: Capture, of lane: Lane, in session: Session, result: CaptureResult) async {
        // Captures stopped on purpose, by a switch or the end of the recording, aren't current.
        guard self.session === session, lane.current?.id == capture.id else { return }

        guard let error = result.error, case .deviceNotFound? = error as? AudioCaptureError else {
            if let error = result.error {
                logger.error("Capture failed: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("Capture ended by the system")
            }
            await end(session, interruption: result.error)
            return
        }

        logger.info("\(capture.device.name, privacy: .public) went away, looking for a replacement")
        lane.current = nil
        clearLevel(of: capture.device)
        session.unavailableDeviceIDs.insert(capture.device.id)
        session.lastCaptureError = error
        session.pendingReplacements += 1
        await capture.capture.stop()
        try? await Task.sleep(for: deviceSwitchDelay)
        let devices = await deviceProvider.availableDevices()
        session.pendingReplacements -= 1
        guard self.session === session else { return }
        applyDevices(devices)
        await syncCaptures(of: session)
    }

    /// Starts and stops captures until `session` records `selectedDevices`, then ends the
    /// recording if no input is left. Calls made while it runs make it go around once more.
    private func syncCaptures(of session: Session) async {
        guard self.session === session else { return }
        guard !session.isSyncing else {
            session.needsSync = true
            return
        }
        session.isSyncing = true
        repeat {
            session.needsSync = false
            await applySelection(to: session)
        } while session.needsSync && self.session === session
        session.isSyncing = false

        guard self.session === session, session.activeDevices.isEmpty, session.pendingReplacements == 0 else { return }
        logger.error("No input left to record from")
        await end(session, interruption: session.lastCaptureError)
    }

    /// One pass of `syncCaptures(of:)`. Inputs that are no longer selected stop first, so a lane
    /// switching devices never records from both at once.
    private func applySelection(to session: Session) async {
        let wanted = selectedDevices.filter { !session.unavailableDeviceIDs.contains($0.id) }

        for lane in session.lanes {
            guard let current = lane.current, !wanted.contains(where: { $0.id == current.device.id }) else { continue }
            lane.current = nil
            clearLevel(of: current.device)
            await current.capture.stop()
            logger.info("Stopped recording from \(current.device.name, privacy: .public)")
            guard self.session === session else { return }
        }

        for device in wanted where !session.activeDevices.contains(where: { $0.id == device.id }) {
            guard self.session === session else { return }
            let started: StartedCapture
            do {
                let capture = try captureFactory.makeCapture(for: device)
                started = StartedCapture(device: device, capture: capture, stream: try await capture.start())
            } catch {
                logger.error(
                    "Couldn't switch to \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                session.unavailableDeviceIDs.insert(device.id)
                session.lastCaptureError = error
                // Falls back to the default microphone, if that's another device.
                reconcileSelection()
                continue
            }
            guard self.session === session else {
                await started.capture.stop()
                return
            }
            // A microphone replacing another continues its track.
            let lane = session.lanes.first { $0.kind == device.kind && $0.current == nil }
                ?? session.addLane(kind: device.kind)
            attach(started, to: lane, in: session)
            logger.info("Now recording from \(device.name, privacy: .public)")
        }
    }

    // MARK: - Levels

    private func updateLevel(_ level: InputLevel, of deviceID: String, sessionID: UUID) {
        // Levels still in flight when the recording ends or the device is switched off are dropped.
        guard let session, session.id == sessionID, session.activeDevices.contains(where: { $0.id == deviceID })
        else { return }
        inputLevels[deviceID] = level
        if !level.isSilent, heardDeviceIDs.insert(deviceID).inserted {
            silenceChecks.removeValue(forKey: deviceID)?.cancel()
            silentDevices.removeAll { $0.id == deviceID }
        }
    }

    /// Lists `device` in `silentDevices` if it's still recording but hasn't been heard once
    /// `silenceWarningDelay` has passed. For system audio, only the time other apps play audio
    /// counts, so a recording with nothing playing isn't flagged.
    private func scheduleSilenceCheck(of device: AudioInputDevice, in session: Session) {
        silenceChecks[device.id]?.cancel()
        let playbackMonitor = device.kind == .systemAudio ? playbackMonitor : nil
        silenceChecks[device.id] = Task { [weak self, silenceWarningDelay] in
            let step = silenceWarningDelay / 10
            var silentFor = Duration.zero
            while silentFor < silenceWarningDelay {
                try? await Task.sleep(for: step)
                guard !Task.isCancelled else { return }
                if await playbackMonitor?.isOtherAudioPlaying() ?? true {
                    silentFor += step
                }
            }
            guard !Task.isCancelled else { return }
            self?.flagIfSilent(device, in: session)
        }
    }

    private func flagIfSilent(_ device: AudioInputDevice, in session: Session) {
        guard self.session === session, session.activeDevices.contains(where: { $0.id == device.id }),
            !heardDeviceIDs.contains(device.id), !silentDevices.contains(where: { $0.id == device.id })
        else { return }
        silentDevices.append(device)
        logger.info("No sound yet from \(device.name, privacy: .public)")
    }

    /// Forgets the level of a device the recording no longer records from.
    private func clearLevel(of device: AudioInputDevice) {
        silenceChecks.removeValue(forKey: device.id)?.cancel()
        inputLevels[device.id] = nil
        silentDevices.removeAll { $0.id == device.id }
    }

    private func resetLevels() {
        silenceChecks.values.forEach { $0.cancel() }
        silenceChecks = [:]
        heardDeviceIDs = []
        inputLevels = [:]
        silentDevices = []
    }

    /// Shown only once the note is written; the audio itself is never kept.
    nonisolated static func interruptedMessage(for error: any Error) -> String {
        "Recording stopped early. \(error.localizedDescription) The note has what was recorded until then."
    }
}
