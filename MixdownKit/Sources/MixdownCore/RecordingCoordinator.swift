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
/// A recording can be paused: its inputs stop, so nothing is recorded and macOS shows no
/// microphone in use, and start again on resume. The paused time is left out of the audio, so
/// the note's duration and times count only what was recorded.
///
/// Engines that transcribe live instead turn each input into text while it's recorded, shown as
/// `liveTranscript`, and the note is written from that text. Their audio isn't kept, so a long
/// recording takes no more memory than a short one.
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
        /// Starting the captures, which waits on the user while macOS asks for permission to record.
        case startingCapture
        /// `startedAt` moves later by the time spent paused, so the time since it is the time
        /// recorded. `recordingStartedAt` is when the recording really started.
        case recording(startedAt: Date)
        /// Recording, but paused after `recorded` seconds. Nothing is captured until it resumes.
        case paused(recorded: TimeInterval)
        /// `progress` is 0...1 across all of the recording's sources.
        case transcribing(progress: Double)
        /// Summarizing the transcript before the note is saved.
        case summarizing
        case failed(message: String)
    }

    /// Recordings shorter than this are discarded without transcribing, with `tooShortMessage`.
    nonisolated static let minimumRecordingDuration: TimeInterval = 0.5

    /// Audio is handed to live sessions in pieces of at least this many samples (320 ms, the step
    /// Nemotron works in) rather than per capture buffer, which can be a hundred times a second.
    nonisolated static let liveFeedSampleCount = 5_120

    public private(set) var phase: Phase = .idle {
        didSet { modelError = nil }
    }
    /// The message of a `.failed` phase caused by the model failing to download, load or delete,
    /// as opposed to e.g. a capture error. `nil` once the phase changes.
    public private(set) var modelError: String?
    public private(set) var devices: [AudioInputDevice] = []
    /// Inputs the running recording captures, or the next one will, in `devices` order.
    public private(set) var selectedDevices: [AudioInputDevice] = []
    /// When the recording in progress started, paused or not; `nil` when there's none.
    public private(set) var recordingStartedAt: Date?
    /// Location of the most recently written note.
    public private(set) var lastNoteURL: URL?
    /// Whether the current recording is transcribed live. Stays true until its note is written.
    public private(set) var showsLiveTranscript = false
    /// What the inputs said so far while `showsLiveTranscript`, else empty.
    public private(set) var liveTranscript = LiveTranscript(speakers: [])
    /// Saves finished notes. `nil` while there's no folder to save to; recording waits for one.
    /// Setting it saves `pendingNotes`.
    public var noteWriter: (any NoteWriting)? {
        didSet {
            noteWriterGeneration &+= 1
            guard !pendingNotes.isEmpty else { return }
            Task { await savePendingNotes() }
        }
    }
    /// Finished notes that couldn't be saved yet, oldest first, e.g. because the notes folder is on
    /// a drive that was disconnected or asleep when the recording finished. They're saved as soon
    /// as there's a `noteWriter` again, and retried every `pendingNoteRetryInterval` meanwhile.
    /// Only kept in memory, so they're lost if the app quits.
    public private(set) var pendingNotes: [Note] = []
    /// True while `pendingNotes` are being written.
    public private(set) var isSavingPendingNotes = false
    /// Adds a summary to each note. `nil` while summaries are off.
    public var summarizer: (any Summarizer)?
    /// The summary template for recordings started by hand.
    public var summaryTemplate: SummaryTemplate
    /// The summary template for recordings started for a call. See `markRecordingAsCall(automatically:)`.
    public var callSummaryTemplate: SummaryTemplate
    /// The summary template of the recording in progress, from its start until its summary is
    /// begun; `nil` otherwise. Starts as `summaryTemplate`, or `callSummaryTemplate` once the
    /// recording is marked as a call, until the user picks one with `chooseSummaryTemplate(_:)`.
    public private(set) var recordingSummaryTemplate: SummaryTemplate?
    /// Whether the user picked `recordingSummaryTemplate`, so marking a call keeps it.
    @ObservationIgnored private var isRecordingSummaryTemplateChosen = false
    public var options: TranscriptionOptions {
        didSet {
            guard options.language != oldValue.language else { return }
            engine.languageDidChange(to: options.language)
            isModelDownloaded = engine.isDownloaded
            Task { await refreshModelStatus() }
        }
    }
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

    /// How long to wait before trying to save `pendingNotes` again, while there's a `noteWriter`
    /// that failed to write them.
    var pendingNoteRetryInterval: Duration = .seconds(30)

    /// How long to wait after a device goes away mid-recording before picking its replacement,
    /// so the system has made another device the default by then.
    var deviceSwitchDelay: Duration = .milliseconds(500)

    public var engineInfo: TranscriptionEngineInfo { engine.info }

    /// Whether the model is on disk. Recording waits for it, since fetching it can take many
    /// minutes; `prepareEngine()` downloads it.
    public private(set) var isModelDownloaded: Bool

    /// True while `deleteModel()` removes the model's files.
    public private(set) var isDeletingModel = false

    /// True while `.preparingModel` downloads the model again for a finished recording, because it
    /// went away while recording, e.g. macOS removed Apple's speech model. The recording waits on
    /// it, so `cancelPreparation()` can't stop it.
    public private(set) var isPreparingModelForRecording = false

    /// A recording is under way, paused or not.
    public var isRecording: Bool {
        switch phase {
        case .recording, .paused: true
        default: false
        }
    }

    public var isPaused: Bool {
        if case .paused = phase { true } else { false }
    }

    /// Recording, and not paused.
    public var canPauseRecording: Bool {
        if case .recording = phase { true } else { false }
    }

    /// Recording, or starting to. Stopping while the captures start ends the recording as soon as
    /// they have.
    public var canStopRecording: Bool {
        isRecording || isStartingCapture
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
    private let hostClock: @Sendable () -> TimeInterval
    private let logger = Logger(subsystem: "app.mixdown", category: "coordinator")
    /// Changes with every `noteWriter`, so a save that failed can tell it has a new one to try.
    @ObservationIgnored private var noteWriterGeneration = 0
    @ObservationIgnored private var pendingNoteRetry: Task<Void, Never>?
    /// The message of the `.failed` phase that says a note is waiting to be saved, cleared once
    /// it's saved.
    @ObservationIgnored private var unsavedNoteMessage: String?

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
    private var isStartingCapture: Bool { phase == .startingCapture }
    /// Whether `stopRecording()` was called while the captures were starting, to be done once
    /// they have.
    @ObservationIgnored private var isStopPending = false
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
        var trigger = RecordingTrigger.manual
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
        /// When the recording was paused, on the host clock; `nil` unless paused, or resumed and
        /// waiting for its first input to start again.
        var pausedAt: TimeInterval?
        /// Whether the recording is paused. No input starts while it is.
        var isPaused = false
        /// Stops the inputs for a pause; resuming waits for it.
        var pausing: Task<Void, Never>?
        /// The time spent paused so far, on the host clock. Taken off the host time of everything
        /// captured afterwards, which leaves the pauses out of the tracks.
        var pausedDuration: TimeInterval = 0

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
            let lane = Lane(kind: kind, index: lanes.count)
            lanes.append(lane)
            return lane
        }
    }

    /// One input of a session, such as "the microphone", recorded into a single track. Its device
    /// can change mid-recording; each device it used has a capture of its own.
    @MainActor
    private final class Lane {
        let kind: AudioSourceKind
        /// Position in the session's lanes, which is also the lane's source in `liveTranscript`.
        let index: Int
        /// Every capture of the lane, the current one last.
        private(set) var captures: [Capture] = []
        /// The capture recording right now. `nil` while switching devices, after the device went
        /// away, or once the input is turned off.
        var current: Capture?

        init(kind: AudioSourceKind, index: Int) {
            self.kind = kind
            self.index = index
        }

        /// The device the lane started with. The transcript names each part by the device that
        /// recorded it.
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
        /// Feeds the audio to a live session, if the engine transcribes live. Returns the error
        /// that stopped it early, if any.
        let live: Task<(any Error)?, Never>?
    }

    /// Audio a consumer is handing to the live session.
    private struct LiveFeed: Sendable {
        let samples: [Float]
        /// The capture's `startHostTime`, which the session's times count from.
        let startHostTime: TimeInterval?
    }

    /// Everything a capture stream produced, plus the error that ended it early, if any.
    private struct CaptureResult: Sendable {
        var track: AudioTrack
        var error: (any Error)?
    }

    /// A lane's captures joined into one track, and where in it each device's audio begins.
    private struct LaneAudio: Sendable {
        var track = AudioTrack()
        var parts: [DevicePart] = []
    }

    /// Where a device's audio begins in a lane's track, in seconds from its first sample.
    private struct DevicePart: Sendable {
        let device: AudioInputDevice
        let start: TimeInterval
    }

    /// A finished lane's audio, positioned on the recording's timeline.
    private struct RecordedTrack: Sendable {
        /// The lane's `index`.
        let lane: Int
        /// The device the lane started with.
        let device: AudioInputDevice
        /// Which device recorded which part; more than one if the lane switched devices.
        let parts: [DevicePart]
        /// Empty when the engine transcribes live.
        let samples: [Float]
        let duration: TimeInterval
        /// Seconds from the start of the recording to the track's first sample.
        let offset: TimeInterval

        var end: TimeInterval { offset + duration }

        /// The device recording at `time`, in seconds on the recording's timeline.
        func device(at time: TimeInterval) -> AudioInputDevice {
            parts.last { $0.start <= time - offset }?.device ?? device
        }
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
    ///   - pendingNotes: Notes still to be saved, from the coordinator this one replaces. See
    ///     `takePendingNotes()`.
    ///   - preferredDeviceIDs: Devices to select when they're available, e.g. the user's last choice.
    ///   - playbackMonitor: Tells silent system audio with nothing playing from a missing permission.
    ///     Without one, system audio is flagged like a microphone.
    ///   - now: Clock used for recording start times. Injectable for tests.
    ///   - hostClock: Seconds on the clock of `AudioChunk.hostTime`, to measure pauses with.
    ///     `systemUptime` counts `mach_absolute_time` on macOS. Injectable for tests.
    public init(
        deviceProvider: any AudioDeviceProvider,
        captureFactory: any AudioCaptureFactory,
        engine: any TranscriptionEngine,
        noteWriter: (any NoteWriting)?,
        pendingNotes: [Note] = [],
        summarizer: (any Summarizer)? = nil,
        summaryTemplate: SummaryTemplate = .general,
        callSummaryTemplate: SummaryTemplate = .general,
        options: TranscriptionOptions = .init(),
        sourceLabels: SourceLabels = .init(),
        preferredDeviceIDs: [String] = [],
        playbackMonitor: (any AudioPlaybackMonitoring)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        hostClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.deviceProvider = deviceProvider
        self.captureFactory = captureFactory
        self.engine = engine
        engine.languageDidChange(to: options.language)
        self.isModelDownloaded = engine.isDownloaded
        self.noteWriter = noteWriter
        self.summarizer = summarizer
        self.summaryTemplate = summaryTemplate
        self.callSummaryTemplate = callSummaryTemplate
        self.options = options
        self.sourceLabels = sourceLabels
        self.preferredDeviceIDs = preferredDeviceIDs
        self.playbackMonitor = playbackMonitor
        self.now = now
        self.hostClock = hostClock
        self.pendingNotes = pendingNotes
        if !pendingNotes.isEmpty {
            Task { await savePendingNotes() }
        }
    }

    // MARK: - Devices

    /// Selects the devices to record and remembers them as preferred. While recording, the
    /// recording switches to them. Ignored while the recording starts, and for an empty list.
    /// Returns whether the selection was applied.
    @discardableResult
    public func selectDevices(_ selection: [AudioInputDevice]) -> Bool {
        guard !isStartingCapture, !selection.isEmpty else { return false }
        preferredDeviceIDs = selection.map(\.id)
        // Choosing a device that went away mid-recording tries it again, and so does choosing
        // System Default for the default microphone.
        if let session {
            session.unavailableDeviceIDs.subtract(preferredDeviceIDs)
            if followsDefaultMicrophone, let defaultMicrophone = Self.defaultMicrophone(in: devices) {
                session.unavailableDeviceIDs.remove(defaultMicrophone.id)
            }
        }
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
        // A paused recording records from the selection once it resumes.
        guard !session.isPaused else { return }
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
        let defaultMicrophone = Self.defaultMicrophone(in: devices)

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

    /// The system's default microphone, else the first one.
    private nonisolated static func defaultMicrophone(in devices: [AudioInputDevice]) -> AudioInputDevice? {
        devices.first { $0.kind == .microphone && $0.isDefault } ?? devices.first { $0.kind == .microphone }
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

    /// Re-checks whether the model is downloaded, for an engine that can only tell asynchronously
    /// (see `TranscriptionEngine.refreshDownloadStatus()`). Call it once the coordinator is created.
    public func refreshModelStatus() async {
        await engine.refreshDownloadStatus()
        isModelDownloaded = engine.isDownloaded
    }

    /// Stops an in-progress model download. Files already fetched are kept, so the next
    /// `prepareEngine()` (or recording) resumes from them. Ignored while
    /// `isPreparingModelForRecording`.
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
        phase = .startingCapture
        isStopPending = false
        // Held until `end(_:interruption:)` has transcribed the recording.
        engine.recordingWillStart()

        let startedCaptures: [StartedCapture]
        do {
            startedCaptures = try await startCaptures(for: devices)
        } catch {
            logger.error("Starting capture failed: \(error.localizedDescription, privacy: .public)")
            engine.recordingDidFinish()
            isStopPending = false
            phase = .failed(message: error.localizedDescription)
            reconcileSelection()
            return
        }

        let session = Session(startedAt: now())
        self.session = session
        recordingStartedAt = session.startedAt
        recordingSummaryTemplate = summaryTemplate
        isRecordingSummaryTemplateChosen = false
        if engine.transcribesLive {
            liveTranscript = LiveTranscript(speakers: [])
            showsLiveTranscript = true
        }
        for started in startedCaptures {
            attach(started, to: addLane(kind: started.device.kind, to: session), in: session)
        }
        phase = .recording(startedAt: session.startedAt)
        let names = devices.map(\.name).joined(separator: " + ")
        logger.info("Recording started on \(names, privacy: .public)")
        if isStopPending {
            isStopPending = false
            logger.info("Stopping the recording, as it was stopped while starting")
            await end(session, interruption: nil)
            return
        }
        // Catches devices that changed while the captures were starting.
        reconcileSelection()
    }

    /// Adds a lane to `session`, and a source for it to `liveTranscript`.
    private func addLane(kind: AudioSourceKind, to session: Session) -> Lane {
        let lane = session.addLane(kind: kind)
        if showsLiveTranscript { liveTranscript.addSource() }
        return lane
    }

    /// Makes `started` the lane's current capture: drains its stream into a track, watches for it
    /// ending on its own, and checks that it isn't silent. With a live engine, also transcribes it.
    private func attach(_ started: StartedCapture, to lane: Lane, in session: Session) {
        // The first input to start again after a pause ends it.
        if let pausedAt = session.pausedAt {
            session.pausedDuration += max(hostClock() - pausedAt, 0)
            session.pausedAt = nil
        }
        let hostTimeShift = session.pausedDuration
        let stream = started.stream
        let deviceID = started.device.id
        let sessionID = session.id
        let transcribesLive = engine.transcribesLive
        let feed = transcribesLive ? AsyncStream<LiveFeed>.makeStream() : nil
        let consumer = Task.detached(priority: .userInitiated) { [weak self] () async -> CaptureResult in
            var track = AudioTrack(keepsSamples: !transcribesLive)
            var meter = LevelMeter()
            var unfed: [Float] = []
            defer {
                if !unfed.isEmpty {
                    feed?.continuation.yield(LiveFeed(samples: unfed, startHostTime: track.startHostTime))
                }
                feed?.continuation.finish()
            }
            do {
                for try await captured in stream {
                    // Moved back by the time spent paused, so the pause leaves no gap to fill.
                    let chunk =
                        hostTimeShift > 0
                        ? AudioChunk(
                            samples: captured.samples,
                            startTime: captured.startTime,
                            hostTime: captured.hostTime.map { $0 - hostTimeShift }
                        )
                        : captured
                    // Including silence filled into a gap, so the live session's clock stays in step
                    // with the track's.
                    let added = track.append(chunk)
                    if feed != nil {
                        unfed.append(contentsOf: added)
                        if unfed.count >= RecordingCoordinator.liveFeedSampleCount {
                            feed?.continuation.yield(LiveFeed(samples: unfed, startHostTime: track.startHostTime))
                            unfed.removeAll(keepingCapacity: true)
                        }
                    }
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
        let live = feed.map { feed in
            // A lane's captures are transcribed one after another, so its words stay in order.
            let previous = lane.captures.last?.live
            let source = lane.index
            let options = options
            return Task { [weak self] () -> (any Error)? in
                _ = await previous?.value
                guard let self else { return nil }
                return await self.transcribeLive(feed.stream, source: source, options: options)
            }
        }
        let capture = Capture(device: started.device, capture: started.capture, consumer: consumer, live: live)
        lane.add(capture)
        Task { [weak self] in
            let result = await consumer.value
            await self?.captureDidEnd(capture, of: lane, in: session, result: result)
        }
        // The note would miss everything after live transcription stops, so the recording ends.
        if let live {
            Task { [weak self] in
                if let error = await live.value { await self?.end(session, interruption: error) }
            }
        }
        scheduleSilenceCheck(of: started.device, in: session)
        if showsLiveTranscript { labelLiveSources(of: session) }
    }

    /// Labels the live transcript's sources like the note's: only when there are several.
    private func labelLiveSources(of session: Session) {
        let devices = session.lanes.compactMap(\.firstDevice)
        for lane in session.lanes {
            let label = devices.count > 1 ? lane.firstDevice.map { sourceLabels.label(for: $0, among: devices) } : nil
            liveTranscript.setSpeaker(label, ofSource: lane.index)
        }
    }

    /// Feeds one capture's audio to a live session and adds what it recognizes to
    /// `liveTranscript`, until the capture ends. Returns the error that stopped it early, if any.
    private func transcribeLive(
        _ feed: AsyncStream<LiveFeed>,
        source index: Int,
        options: TranscriptionOptions
    ) async -> (any Error)? {
        do {
            // Loads the model if it isn't yet; the feed buffers the audio meanwhile.
            let live = try await engine.makeLiveSession(options: options)
            // Its words come from another device than the lane's previous session's.
            liveTranscript.breakSegment(ofSource: index)
            var startHostTime: TimeInterval?
            for await item in feed {
                startHostTime = item.startHostTime
                let update = try await live.push(item.samples)
                liveTranscript.apply(update, fromSource: index, startHostTime: startHostTime)
            }
            let update = try await live.finish()
            liveTranscript.apply(update, fromSource: index, startHostTime: startHostTime)
            return nil
        } catch {
            logger.error("Live transcription failed: \(error.localizedDescription, privacy: .public)")
            return error
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

    /// Stops capture, transcribes, writes the note and updates `lastNoteURL`. While the captures
    /// are starting, e.g. waiting on a permission prompt, it stops them as soon as they've started.
    public func stopRecording() async {
        guard !isStartingCapture else {
            isStopPending = true
            return
        }
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
        recordingStartedAt = nil
        resetLevels()
        let lanes = await endCaptures(of: session)
        let liveError = await finishLiveTranscription(of: session)
        await finish(session, lanes: lanes, interruption: interruption ?? liveError)
        recordingSummaryTemplate = nil
        engine.recordingDidFinish()
    }

    /// Waits for `session`'s live sessions to transcribe the rest of their input. Returns the
    /// first error that stopped one.
    private func finishLiveTranscription(of session: Session) async -> (any Error)? {
        let live = session.lanes.flatMap { $0.captures.compactMap(\.live) }
        guard !live.isEmpty else { return nil }
        phase = .transcribing(progress: 0)
        var firstError: (any Error)?
        for task in live {
            if let error = await task.value { firstError = firstError ?? error }
        }
        return firstError
    }

    /// Stops every capture of `session` and joins what each lane recorded into one track per lane.
    private func endCaptures(of session: Session) async -> [LaneAudio] {
        let running = session.lanes.compactMap(\.current)
        for lane in session.lanes {
            lane.current = nil
        }
        await withTaskGroup(of: Void.self) { group in
            for capture in running.map(\.capture) {
                group.addTask { await capture.stop() }
            }
        }
        var lanes: [LaneAudio] = []
        for lane in session.lanes {
            var audio = LaneAudio(track: AudioTrack(keepsSamples: !engine.transcribesLive))
            for capture in lane.captures {
                let track = await capture.consumer.value.track
                audio.track.append(track)
                // Counted by length, as live tracks keep no samples.
                guard track.duration > 0 else { continue }
                audio.parts.append(DevicePart(device: capture.device, start: audio.track.duration - track.duration))
            }
            lanes.append(audio)
        }
        return lanes
    }

    /// Transcribes and saves a finished recording, one track per lane of `session`.
    private func finish(_ session: Session, lanes: [LaneAudio], interruption: (any Error)?) async {
        reconcileSelection()
        defer {
            showsLiveTranscript = false
            liveTranscript = LiveTranscript(speakers: [])
        }

        let offsets = AudioTrack.startOffsets(of: lanes.map(\.track))
        let tracks = zip(session.lanes, lanes).enumerated().compactMap { index, pair -> RecordedTrack? in
            guard let device = pair.0.firstDevice else { return nil }
            return RecordedTrack(
                lane: index,
                device: device,
                parts: pair.1.parts,
                samples: pair.1.track.samples,
                duration: pair.1.track.duration,
                offset: offsets[index]
            )
        }
        let duration = tracks.map(\.end).max() ?? 0
        guard duration >= Self.minimumRecordingDuration else {
            logger.info("Discarding \(duration, format: .fixed(precision: 2)) s recording as too short")
            // An interruption this early explains itself, like capture failing to start.
            phase = .failed(message: interruption?.localizedDescription ?? Self.tooShortMessage)
            return
        }

        progressEstimator = RemainingTimeEstimator()
        progressEstimator.add(progress: 0, at: now())
        phase = .transcribing(progress: 0)
        do {
            try await prepareModelIfMissing()
            let transcript: Transcript
            var trackFailure: TrackFailure?
            if engine.transcribesLive {
                transcript = transcriptFromLiveText(tracks)
            } else if let track = tracks.first, tracks.count == 1 {
                transcriptionProgress = TranscriptionProgress(sessionID: session.id, tracks: tracks)
                transcript = try await engine.transcribe(
                    track.samples,
                    options: options,
                    progress: progressHandler(track: 0, sessionID: session.id)
                )
            } else {
                (transcript, trackFailure) = try await transcribeSeparately(tracks, session: session)
            }
            let template = recordingSummaryTemplate ?? (session.isCall ? callSummaryTemplate : summaryTemplate)
            // The template can't change once the summary is under way.
            recordingSummaryTemplate = nil
            let summary = await summarize(transcript, template: template)
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
                summary: summary,
                trigger: session.trigger
            )
            // Kept until it's saved: the folder can go away while recording or transcribing, e.g.
            // when its drive is disconnected or goes to sleep.
            pendingNotes.append(note)
            let saveError = await savePendingNotes()
            let messages = [
                interruption.map(Self.interruptedMessage(for:)),
                trackFailure.map { Self.untranscribedMessage(for: $0.devices, error: $0.error) },
                pendingNotes.isEmpty ? nil : Self.unsavedMessage(for: saveError ?? NoteWritingError.noFolder),
            ].compactMap { $0 }
            if messages.isEmpty {
                phase = .idle
            } else {
                let message = messages.joined(separator: " ")
                unsavedNoteMessage = pendingNotes.isEmpty ? nil : message
                phase = .failed(message: message)
            }
            // A live model that failed to load needs the same retry as an offline one.
            if let interruption, case TranscriptionError.modelUnavailable = interruption {
                modelError = interruption.localizedDescription
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

    /// Writes `pendingNotes`, oldest first, updating `lastNoteURL` for each. Stops at the first that
    /// fails, returning its error, and tries again after `pendingNoteRetryInterval` if there's a
    /// `noteWriter`; without one, it waits for the next. Returns `nil` right away if a save is
    /// already under way; that one saves notes added meanwhile too.
    @discardableResult
    private func savePendingNotes() async -> (any Error)? {
        guard !isSavingPendingNotes else { return nil }
        isSavingPendingNotes = true
        defer { isSavingPendingNotes = false }
        pendingNoteRetry?.cancel()
        pendingNoteRetry = nil

        while let note = pendingNotes.first {
            let generation = noteWriterGeneration
            do {
                guard let noteWriter else { throw NoteWritingError.noFolder }
                let url = try await noteWriter.write(note)
                pendingNotes.removeFirst()
                lastNoteURL = url
                logger.info("Wrote note to \(url.path(percentEncoded: false), privacy: .private)")
            } catch {
                // The folder changed while writing; try the new one.
                if generation != noteWriterGeneration { continue }
                let count = pendingNotes.count
                logger.error(
                    "Saving \(count) note(s) failed, keeping them: \(error.localizedDescription, privacy: .public)"
                )
                if noteWriter != nil { schedulePendingNoteRetry() }
                return error
            }
        }
        if let unsavedNoteMessage, phase == .failed(message: unsavedNoteMessage) {
            phase = .idle
        }
        unsavedNoteMessage = nil
        return nil
    }

    private func schedulePendingNoteRetry() {
        pendingNoteRetry = Task { [weak self, interval = pendingNoteRetryInterval] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self else { return }
            // So saving doesn't cancel the task doing it.
            pendingNoteRetry = nil
            await savePendingNotes()
        }
    }

    /// Removes and returns `pendingNotes`, for the coordinator replacing this one. Returns nothing
    /// while they're being saved, as they may already be written.
    public func takePendingNotes() -> [Note] {
        guard !isSavingPendingNotes else { return [] }
        pendingNoteRetry?.cancel()
        pendingNoteRetry = nil
        defer { pendingNotes = [] }
        return pendingNotes
    }

    /// Downloads the model again if it went away while recording, as macOS may remove its own
    /// speech model at any time. Shown as `.preparingModel` with its progress, rather than as a
    /// transcription stuck at 0% while the engine fetches the model by itself. Returns to
    /// `.transcribing` once it's back.
    private func prepareModelIfMissing() async throws {
        await engine.refreshDownloadStatus()
        isModelDownloaded = engine.isDownloaded
        guard !isModelDownloaded else { return }

        logger.info("Model went away while recording; downloading it again")
        progressEstimator = RemainingTimeEstimator()
        progressEstimator.add(progress: 0, at: now())
        phase = .preparingModel(progress: 0)
        isPreparingModelForRecording = true
        defer {
            isPreparingModelForRecording = false
            isModelDownloaded = engine.isDownloaded
        }
        try await engine.prepare { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.updatePreparationProgress(progress)
            }
        }

        progressEstimator = RemainingTimeEstimator()
        progressEstimator.add(progress: 0, at: now())
        phase = .transcribing(progress: 0)
    }

    /// The transcript's summary, or `nil` if there's no summarizer, it isn't available or it
    /// fails. The note is saved either way, so a failure is only logged.
    private func summarize(_ transcript: Transcript, template: SummaryTemplate) async -> NoteSummary? {
        guard let summarizer, !transcript.isEmpty else { return nil }
        let name = summarizer.info.displayName
        if case .unavailable(let reason) = summarizer.availability {
            logger.info("Not summarizing, \(name, privacy: .public) is unavailable: \(reason, privacy: .public)")
            return nil
        }
        phase = .summarizing
        do {
            let summary = try await summarizer.summarize(transcript, template: template)
            return summary.isEmpty ? nil : summary
        } catch {
            logger.error(
                "Summarizing with \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// The note's transcript from what the live sessions recognized: per track like
    /// `transcribeSeparately`, merged by time when there are several.
    private func transcriptFromLiveText(_ tracks: [RecordedTrack]) -> Transcript {
        let transcripts = tracks.map { track in
            let segments = liveTranscript.segments(fromSource: track.lane).map { segment in
                var segment = segment
                segment.start += track.offset
                segment.end += track.offset
                return segment
            }
            return Transcript(segments: segments, language: options.language)
        }
        guard tracks.count > 1 else { return transcripts.first ?? Transcript(segments: []) }
        let lanes = tracks.map(\.device)
        let sources = zip(tracks, transcripts).flatMap { track, transcript in
            Self.split(transcript, byDeviceOf: track).map { device, part in
                SourceTranscript(device: device, label: sourceLabels.label(for: device, among: lanes), transcript: part)
            }
        }
        return TranscriptMerger.merge(sources)
    }

    /// Tracks of a recording that couldn't be transcribed, and why the first of them failed.
    private struct TrackFailure {
        /// Every device that recorded a part of the failed tracks.
        let devices: [AudioInputDevice]
        let error: any Error
    }

    /// Transcribes each track on its own, so speech stays attributed to its source, then merges the
    /// labeled transcripts by time. Tracks are submitted together; the engine decides how many it
    /// runs at once (speech-swift runs one at a time, since they share the GPU anyway).
    ///
    /// A track that fails doesn't take the others with it: the transcript has the tracks that
    /// worked, and the failure is returned alongside. Throws only if every track failed.
    private func transcribeSeparately(
        _ tracks: [RecordedTrack],
        session: Session
    ) async throws -> (Transcript, TrackFailure?) {
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
        let results = await withTaskGroup(
            of: (Int, Result<Transcript, any Error>).self,
            returning: [Result<Transcript, any Error>].self
        ) { group in
            for (index, track) in audible.enumerated() {
                let progress = progressHandler(track: index, sessionID: session.id)
                group.addTask {
                    do {
                        var transcript = try await engine.transcribe(track.samples, options: options, progress: progress)
                        for i in transcript.segments.indices {
                            transcript.segments[i].start += track.offset
                            transcript.segments[i].end += track.offset
                        }
                        // Engines needn't report progress (e.g. for a source without speech), but the
                        // bar mustn't wait on a source that's done.
                        progress(1)
                        return (index, .success(transcript))
                    } catch {
                        // A failed source is done too, as far as the bar is concerned.
                        progress(1)
                        return (index, .failure(error))
                    }
                }
            }
            var results = [Result<Transcript, any Error>](
                repeating: .failure(CancellationError()),
                count: audible.count
            )
            for await (index, result) in group {
                results[index] = result
            }
            return results
        }

        // A lane that switched microphones becomes one source per device, so with several
        // microphones each part is named after the device that recorded it.
        let lanes = tracks.map(\.device)
        var sources: [SourceTranscript] = []
        var failedDevices: [AudioInputDevice] = []
        var firstError: (any Error)?
        var anyTranscribed = false
        for (track, result) in zip(audible, results) {
            switch result {
            case .success(let transcript):
                anyTranscribed = true
                sources += Self.split(transcript, byDeviceOf: track).map { device, part in
                    SourceTranscript(device: device, label: sourceLabels.label(for: device, among: lanes), transcript: part)
                }
            case .failure(let error):
                logger.error(
                    "Transcribing \(track.device.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                firstError = firstError ?? error
                for device in track.parts.map(\.device) where !failedDevices.contains(where: { $0.id == device.id }) {
                    failedDevices.append(device)
                }
            }
        }
        // With nothing transcribed there's no note to save, so the recording fails as a whole.
        if let firstError, !anyTranscribed { throw firstError }
        let failure = firstError.map { TrackFailure(devices: failedDevices, error: $0) }
        return (TranscriptMerger.merge(sources), failure)
    }

    /// `transcript`'s segments grouped by the device that recorded them, in order of first use.
    private nonisolated static func split(
        _ transcript: Transcript,
        byDeviceOf track: RecordedTrack
    ) -> [(device: AudioInputDevice, transcript: Transcript)] {
        var parts: [(device: AudioInputDevice, transcript: Transcript)] = []
        for segment in transcript.segments {
            let device = track.device(at: segment.start)
            if let index = parts.firstIndex(where: { $0.device.id == device.id }) {
                parts[index].transcript.segments.append(segment)
            } else {
                parts.append((device, Transcript(segments: [segment], language: transcript.language)))
            }
        }
        return parts
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

    /// Marks the recording in progress as a call, so its note is titled as one, e.g. "Call about …",
    /// and, if Mixdown started it by itself, as started automatically. Ignored when not recording.
    public func markRecordingAsCall(automatically: Bool = false) {
        guard let session else { return }
        session.isCall = true
        if automatically { session.trigger = .automatic }
        if !isRecordingSummaryTemplateChosen {
            recordingSummaryTemplate = callSummaryTemplate
        }
    }

    /// Summarizes the recording in progress, or the one being transcribed, with `template`
    /// instead of the default. Ignored when there's no such recording or its summary has begun.
    public func chooseSummaryTemplate(_ template: SummaryTemplate) {
        guard recordingSummaryTemplate != nil else { return }
        recordingSummaryTemplate = template
        isRecordingSummaryTemplateChosen = true
    }

    public func toggleRecording() async {
        if canStopRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    /// Pauses the recording: its inputs stop until `resumeRecording()`. Ignored unless recording
    /// and not paused.
    public func pauseRecording() async {
        guard let session, case .recording(let startedAt) = phase else { return }
        session.isPaused = true
        // Already set if no input started again since the last pause, which then still counts.
        session.pausedAt = session.pausedAt ?? hostClock()
        phase = .paused(recorded: max(now().timeIntervalSince(startedAt), 0))
        // Cleared first, so the inputs ending isn't taken for them going away.
        let running = session.lanes.compactMap(\.current)
        for lane in session.lanes {
            lane.current = nil
        }
        for capture in running {
            clearLevel(of: capture.device)
        }
        let pausing = Task {
            await withTaskGroup(of: Void.self) { group in
                for capture in running.map(\.capture) {
                    group.addTask { await capture.stop() }
                }
            }
        }
        session.pausing = pausing
        await pausing.value
        logger.info("Recording paused")
    }

    /// Records again from the selected inputs, which may have changed while paused. The recording
    /// ends, keeping what it has, if none of them starts. Ignored unless paused.
    public func resumeRecording() async {
        guard let session, case .paused(let recorded) = phase else { return }
        session.isPaused = false
        phase = .recording(startedAt: now().addingTimeInterval(-recorded))
        logger.info("Recording resumed")
        // An input may not start again on a device it hasn't stopped on yet.
        await session.pausing?.value
        session.pausing = nil
        guard self.session === session, !session.isPaused else { return }
        await syncCaptures(of: session)
    }

    public func togglePause() async {
        if isPaused {
            await resumeRecording()
        } else {
            await pauseRecording()
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
    /// the default microphone, and one cut off by the audio service restarting is started again;
    /// anything else ends the whole recording: permission was revoked, or the user stopped capture
    /// from the system's menu bar indicator.
    private func captureDidEnd(_ capture: Capture, of lane: Lane, in session: Session, result: CaptureResult) async {
        // Captures stopped on purpose, by a switch or the end of the recording, aren't current.
        guard self.session === session, lane.current?.id == capture.id else { return }

        let captureError = result.error as? AudioCaptureError
        switch captureError {
        case .deviceNotFound?:
            logger.info("\(capture.device.name, privacy: .public) went away, looking for a replacement")
            session.unavailableDeviceIDs.insert(capture.device.id)
        case .audioServiceRestarted?:
            // Starting it again fails if the device is really gone, which marks it unavailable.
            logger.info("Audio service restarted, starting \(capture.device.name, privacy: .public) again")
        default:
            if let error = result.error {
                logger.error("Capture failed: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("Capture ended by the system")
            }
            await end(session, interruption: result.error)
            return
        }

        lane.current = nil
        clearLevel(of: capture.device)
        session.lastCaptureError = captureError
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
        // Resuming syncs again.
        guard self.session === session, !session.isPaused else { return }
        guard !session.isSyncing else {
            session.needsSync = true
            return
        }
        session.isSyncing = true
        repeat {
            session.needsSync = false
            await applySelection(to: session)
        } while session.needsSync && self.session === session && !session.isPaused
        session.isSyncing = false

        guard self.session === session, !session.isPaused, session.activeDevices.isEmpty,
            session.pendingReplacements == 0
        else { return }
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
            guard self.session === session, !session.isPaused else { return }
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
            // Paused while it started.
            guard self.session === session, !session.isPaused else {
                await started.capture.stop()
                return
            }
            // A microphone replacing another continues its track.
            let lane = session.lanes.first { $0.kind == device.kind && $0.current == nil }
                ?? addLane(kind: device.kind, to: session)
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

    /// Says the note wasn't saved because of `error`, and will be.
    nonisolated static func unsavedMessage(for error: any Error) -> String {
        let reason =
            if case NoteWritingError.noFolder = error {
                "The notes folder isn't available, so the note hasn't been saved yet."
            } else {
                "The note couldn't be saved yet. \(error.localizedDescription)"
            }
        return "\(reason) Mixdown saves it as soon as it can, or once you choose another folder. "
            + "Keep Mixdown open until then."
    }

    /// Shown once a note is written without the speech of `devices`, whose tracks failed to
    /// transcribe; the audio itself is never kept.
    nonisolated static func untranscribedMessage(for devices: [AudioInputDevice], error: any Error) -> String {
        let names = devices.map(\.name).formatted(.list(type: .and))
        return "Couldn't transcribe \(names). \(error.localizedDescription) The note has the other inputs."
    }

    nonisolated static let tooShortMessage =
        "The recording was too short to save. Record for at least half a second."
}
