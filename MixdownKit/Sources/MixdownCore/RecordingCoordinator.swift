import Foundation
import Observation
import os

/// Drives the record → transcribe → write-note flow and exposes its state to the UI.
///
/// Several inputs can be recorded at once, e.g. the microphone for the user and system audio for
/// the other people on a call. Each is captured into its own track, lined up on the host clock,
/// transcribed separately and labeled by `sourceLabels`; the transcripts are then merged by time.
/// A single input is transcribed without labels.
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
/// `liveTranscript`, and the note is written from that text. Their audio isn't kept in memory, so
/// a long recording takes no more memory than a short one.
///
/// With a `recordingStore` and `keepsAudioOnDisk`, every recording's audio is also written to
/// disk as it's recorded, and deleted once its note is saved. A recording whose note wasn't made,
/// as Mixdown quit or crashed or transcribing it failed, stays there, listed in
/// `unfinishedRecordings`. Without, a recording whose transcription failed is listed there too,
/// but only kept in memory, until Mixdown quits.
///
/// Audio and video files can be imported too, with `importAudio(from:)`. They're transcribed,
/// translated and summarized like a recording, and saved as a note of their own.
///
/// Each capture is drained by a `CaptureLoop`. Finished recordings and imported files both go
/// through a `NotePipeline`, which turns their tracks into a saved note.
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
        /// Telling apart the people on the system audio, then naming them, before the transcript is
        /// translated and summarized.
        case identifyingSpeakers
        /// Translating the transcript into `translationLanguage` before it's summarized.
        case translating
        /// Summarizing the transcript before the note is saved.
        case summarizing
        case failed(message: String)
    }

    /// Recordings shorter than this are discarded without transcribing, with `tooShortMessage`:
    /// none of their tracks would be.
    nonisolated static let minimumRecordingDuration = NotePipeline.minimumTrackDuration

    /// See `NotePipeline.liveFeedSampleCount`; recordings feed their live sessions like the
    /// pipeline does.
    nonisolated static let liveFeedSampleCount = NotePipeline.liveFeedSampleCount

    public internal(set) var phase: Phase = .idle {
        didSet { modelError = nil }
    }
    /// The message of a `.failed` phase caused by the model failing to download, load or delete,
    /// as opposed to e.g. a capture error. `nil` once the phase changes.
    public internal(set) var modelError: String?
    public internal(set) var devices: [AudioInputDevice] = []
    /// Inputs the running recording captures, or the next one will, in `devices` order.
    public internal(set) var selectedDevices: [AudioInputDevice] = []
    /// When the recording in progress started, paused or not; `nil` when there's none.
    public internal(set) var recordingStartedAt: Date?
    /// Whether the current recording is transcribed live. Stays true until its note is written.
    public internal(set) var showsLiveTranscript = false
    /// What the inputs said so far while `showsLiveTranscript`, else empty.
    public internal(set) var liveTranscript = LiveTranscript(speakers: [])
    /// Moments added to the recording in progress, in the order they were added, until its note
    /// is made. See `addMoment(at:text:)`.
    public internal(set) var moments: [Moment] = []
    /// `liveTranscript` translated into `translationLanguage` as it's recognized, while
    /// `showsLiveTranscript` and `translatesLiveText`; else `nil`.
    public internal(set) var liveCaptions: LiveCaptions?
    /// The summary template for recordings started by hand.
    public var summaryTemplate: SummaryTemplate
    /// The summary template for recordings started for a call. See `markRecordingAsCall(automatically:)`.
    public var callSummaryTemplate: SummaryTemplate
    /// The summary template of the recording in progress, from its start until its summary is
    /// begun; `nil` otherwise. Starts as `summaryTemplate`, or `callSummaryTemplate` once the
    /// recording is marked as a call, until the user picks one with `chooseSummaryTemplate(_:)`.
    public internal(set) var recordingSummaryTemplate: SummaryTemplate?
    /// Whether the user picked `recordingSummaryTemplate`, so marking a call keeps it.
    @ObservationIgnored var isRecordingSummaryTemplateChosen = false
    /// Whether a recording transcribed live is also translated into `translationLanguage` while
    /// it's recorded, as `liveCaptions`. Changes apply to the next recording.
    public var translatesLiveText = true
    /// Changes apply to the next recording; the one in progress is transcribed with the options it
    /// started with.
    public var options: TranscriptionOptions {
        didSet { syncEngineLanguage() }
    }
    /// Whether to take the echo of the system audio out of the microphones while both record, if
    /// there's an `echoCancellation`. Changes apply to the next recording.
    public var cancelsEcho = true
    /// Whether to time how long the user and the others talk while both a microphone and system
    /// audio record, as `talkTime` and the note's `talkTimeline`. Changes apply to the next
    /// recording.
    public var measuresTalkTime = false
    /// Whether recordings' audio is written to the `recordingStore` until their notes are saved, so
    /// quitting or a crash doesn't lose them. Changes apply to the next recording.
    public var keepsAudioOnDisk = true
    /// Tells apart the people on the system audio once a recording ends, labeling their lines
    /// "Speaker 1", "Speaker 2" and so on; `nil` while that's off. With a live engine, the system
    /// audio is kept for it while recording. Changes apply to the next recording.
    public var speakerDiarizer: (any SpeakerDiarizer)?

    /// Each source's level while recording, by device ID. Changes about ten times a second, so
    /// only read it from views that draw meters.
    public internal(set) var inputLevels: [String: InputLevel] = [:]

    /// How long the user and the others have talked so far, while recording both a microphone and
    /// system audio with `measuresTalkTime`; `nil` otherwise. Changes about ten times a second, so only read it from views
    /// that show it.
    public internal(set) var talkTime: TalkTime?

    /// Sources of the current recording that haven't made a sound since it started, once
    /// `silenceWarningDelay` has passed. A source leaves the list as soon as it's heard.
    ///
    /// Without the System Audio Recording permission the tap keeps running but delivers silence,
    /// so this is the only way a denial shows up before the note comes out empty. As the tap is
    /// just as silent when nothing plays, system audio only counts as silent while another app
    /// plays audio, if there's a `playbackMonitor` to tell.
    public internal(set) var silentDevices: [AudioInputDevice] = []

    /// How long a source may stay silent before it's listed in `silentDevices`. For system audio,
    /// the time other apps play audio.
    var silenceWarningDelay: Duration = .seconds(10)

    /// Whether the recording has gone `stillRecordingDelay` without anyone speaking, on any input,
    /// so it may have been left running by mistake, e.g. after a meeting ended. Cleared once
    /// someone speaks, the recording is paused or stops, or by `keepRecording()`.
    public internal(set) var isAskingIfStillRecording = false

    /// How long a recording may go without speech before `isAskingIfStillRecording`; `nil` to
    /// never ask. Time spent paused doesn't count. Changing it starts the wait over.
    public var stillRecordingDelay: Duration? {
        didSet {
            guard stillRecordingDelay != oldValue, let session else { return }
            startStillRecordingCheck(for: session)
        }
    }

    /// How long to wait after a device goes away mid-recording before picking its replacement,
    /// so the system has made another device the default by then.
    var deviceSwitchDelay: Duration = .milliseconds(500)

    /// How often the live text is checked for lines to translate into `liveCaptions`. A line that
    /// keeps growing is translated again this often, not with every word.
    var liveCaptionInterval: Duration = .milliseconds(500)

    public var engineInfo: TranscriptionEngineInfo { engine.info }

    /// Whether the model is on disk. Recording waits for it, since fetching it can take many
    /// minutes; `prepareEngine()` downloads it.
    public internal(set) var isModelDownloaded: Bool

    /// True while `deleteModel()` removes the model's files.
    public internal(set) var isDeletingModel = false

    /// True while `.preparingModel` downloads the model again for a finished recording, because it
    /// went away while recording, e.g. macOS removed Apple's speech model. The recording waits on
    /// it, so `cancelPreparation()` can't stop it.
    public internal(set) var isPreparingModelForRecording = false

    /// True from `cancelPreparation()` until the download has actually stopped. The phase stays
    /// `.preparingModel` meanwhile, so nothing else starts before it has.
    public internal(set) var isCancellingPreparation = false

    /// Whether `cancelPreparation()` would stop a download: one started by `prepareEngine()` that
    /// isn't being cancelled already.
    public var canCancelPreparation: Bool {
        guard case .preparingModel = phase else { return false }
        return !isPreparingModelForRecording && !isCancellingPreparation
    }

    /// The name of the file `importAudio(from:)` is reading, transcribing or summarizing, until its
    /// note is saved or it fails; `nil` otherwise.
    public internal(set) var importingFileName: String?

    /// Recordings kept without a note, oldest first: in the `recordingStore`, from before Mixdown
    /// last quit or whose transcription failed, and in memory, whose transcription failed since.
    /// See `transcribe(_:)` and `discard(_:)`.
    public internal(set) var unfinishedRecordings: [UnfinishedRecording] = []
    /// The audio of `unfinishedRecordings` that aren't on disk, and of the recording being made
    /// into a note if it isn't, to keep should that fail.
    var recordingsInMemory: [UUID: RecordingStore.StoredRecording] = [:]
    /// Whether the recording being made into a note is in the `recordingStore`.
    var isMakingNoteOfStoredRecording = false

    /// True while `transcribe(_:)` makes a note of one of `unfinishedRecordings`.
    public internal(set) var isTranscribingUnfinishedRecording = false

    /// Idle, there's an `audioFileDecoder`, the model is downloaded and there's a `noteWriter`.
    public var canImportAudio: Bool {
        audioFileDecoder != nil && isIdle && isModelDownloaded && noteWriter != nil
    }

    /// True once `stopRecording()` was called while the captures were starting. The recording
    /// is then discarded as soon as they have, as nothing was recorded yet.
    public internal(set) var isStopPending = false

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

    /// A recording, an unfinished recording or an imported file is being made into a note: it's
    /// transcribed, its speakers told apart, translated or summarized, or it waits on the model.
    public var isMakingNote: Bool {
        switch phase {
        case .transcribing, .identifyingSpeakers, .translating, .summarizing: true
        case .preparingModel: isPreparingModelForRecording
        default: false
        }
    }

    /// Recording, or starting to. Stopping while the captures start ends the recording as soon as
    /// they have.
    public var canStopRecording: Bool {
        isRecording || isStartingCapture
    }

    /// Estimated seconds until the model is ready or the note is transcribed, while preparing or
    /// transcribing. `nil` until there's enough progress to extrapolate from (a few seconds in).
    public var timeRemaining: TimeInterval? {
        switch phase {
        case .preparingModel where isCancellingPreparation: return nil
        case .preparingModel: return progressEstimator.remaining
        case .transcribing: return pipeline.timeRemaining
        default: return nil
        }
    }

    /// Nothing is downloading, deleting, recording, transcribing, translating or summarizing. An
    /// error may be showing.
    public var isIdle: Bool {
        guard session == nil, !isStartingCapture, !isDeletingModel else { return false }
        switch phase {
        case .idle, .failed: return true
        default: return false
        }
    }

    /// Idle, at least one device is selected, the model is downloaded and there's a `noteWriter`.
    public var canStartRecording: Bool {
        isIdle && !selectedDevices.isEmpty && isModelDownloaded && noteWriter != nil
    }

    let deviceProvider: any AudioDeviceProvider
    let captureFactory: any AudioCaptureFactory
    let engine: any TranscriptionEngine
    let playbackMonitor: (any AudioPlaybackMonitoring)?
    let echoCancellation: (any EchoCancellation)?
    /// Reads the files `importAudio(from:)` imports; without one, there's no importing.
    let audioFileDecoder: (any AudioFileDecoding)?
    /// Keeps each recording's audio on disk until its note is saved; without one, it's only kept
    /// in memory.
    let recordingStore: RecordingStore?
    /// Transcribes, translates, summarizes and saves recordings and imports.
    let pipeline: NotePipeline
    let now: @Sendable () -> Date
    let hostClock: @Sendable () -> TimeInterval
    let logger = Logger(subsystem: "app.mixdown", category: "coordinator")
    /// Translates the live text into `liveCaptions` while recording.
    @ObservationIgnored var liveCaptioning: Task<Void, Never>?
    /// The message of the `.failed` phase that says a note is waiting to be saved, cleared once
    /// it's saved.
    @ObservationIgnored var unsavedNoteMessage: String?

    /// The user's choice of inputs, by ID. May hold `AudioInputDevice.defaultMicrophoneID` and
    /// devices that aren't connected; `selectedDevices` is what that resolves to.
    public internal(set) var preferredDeviceIDs: [String]

    /// Whether the microphone follows the system's default input: chosen explicitly, or nothing
    /// was ever chosen.
    public var followsDefaultMicrophone: Bool {
        preferredDeviceIDs.isEmpty || preferredDeviceIDs.contains(AudioInputDevice.defaultMicrophoneID)
    }
    @ObservationIgnored var session: Session?
    /// The recording that stopped and is being torn down, from when `session` is cleared until its
    /// note is begun, or it's kept without one. See `keepsRecordingWhenQuitting`.
    @ObservationIgnored var endingSession: Session?
    /// The import under way, kept so `cancelImport()` can stop it.
    @ObservationIgnored var importing: Task<Void, Never>?
    /// The in-flight `engine.prepare` call, kept so `cancelPreparation()` can stop it.
    @ObservationIgnored var preparation: Task<Void, any Error>?
    /// True while the captures are starting; blocks a second start.
    var isStartingCapture: Bool { phase == .startingCapture }
    /// The language the engine was last told about with `languageDidChange(to:)`.
    @ObservationIgnored var engineLanguage: String?
    /// From `startRecording()` until the recording is transcribed, discarded or failed, while the
    /// engine is held with `recordingWillStart()`. The engine's language doesn't change meanwhile.
    @ObservationIgnored var isEngineHeldForRecording = false
    /// Sources of the current recording that delivered sound at least once.
    @ObservationIgnored var heardDeviceIDs: Set<String> = []
    /// Add each recording device to `silentDevices` once `silenceWarningDelay` has passed, by ID.
    @ObservationIgnored var silenceChecks: [String: Task<Void, Never>] = [:]
    /// Sets `isAskingIfStillRecording` once the recording has gone `stillRecordingDelay` without
    /// speech.
    @ObservationIgnored var stillRecordingCheck: Task<Void, Never>?
    /// Set when someone speaks or the user answers, so `stillRecordingCheck` starts counting again.
    @ObservationIgnored var restartsQuietTime = false
    /// When anyone was last heard speaking, on any input, in the recording going on.
    @ObservationIgnored var lastSpeech: ContinuousClock.Instant?

    /// How long it's been since anyone was heard speaking in the recording going on, on any input;
    /// `nil` if no one has been yet, or there's no recording. Not observable: it changes all the
    /// time.
    public var timeSinceSpeech: Duration? {
        guard isRecording, let lastSpeech else { return nil }
        return .now - lastSpeech
    }
    /// Fed while preparing the model; the pipeline estimates transcription itself.
    var progressEstimator = RemainingTimeEstimator()

    /// - Parameters:
    ///   - pendingNotes: Notes still to be saved, from the coordinator this one replaces. See
    ///     `takePendingNotes()`.
    ///   - recordingsInMemory: Unfinished recordings only kept in memory, from the coordinator this
    ///     one replaces. See `takeRecordingsInMemory()`.
    ///   - preferredDeviceIDs: Devices to select when they're available, e.g. the user's last choice.
    ///   - playbackMonitor: Tells silent system audio with nothing playing from a missing permission.
    ///     Without one, system audio is flagged like a microphone.
    ///   - echoCancellation: Takes the echo of the system audio out of the microphones. See
    ///     `cancelsEcho`.
    ///   - audioFileDecoder: Reads files for `importAudio(from:)`.
    ///   - recordingStore: Keeps the audio of recordings on disk until their notes are saved. Its
    ///     recordings, other than those of `pendingNotes`, become `unfinishedRecordings`.
    ///   - now: Clock used for recording start times. Injectable for tests.
    ///   - hostClock: Seconds on the clock of `AudioChunk.hostTime`, to measure pauses and the time
    ///     recorded with.
    ///     `systemUptime` counts `mach_absolute_time` on macOS. Injectable for tests.
    public init(
        deviceProvider: any AudioDeviceProvider,
        captureFactory: any AudioCaptureFactory,
        engine: any TranscriptionEngine,
        noteWriter: (any NoteWriting)?,
        pendingNotes: [Note] = [],
        recordingsInMemory: RecordingsInMemory = RecordingsInMemory(),
        summarizer: (any Summarizer)? = nil,
        summaryTemplate: SummaryTemplate = .general,
        callSummaryTemplate: SummaryTemplate = .general,
        translator: (any Translator)? = nil,
        translationLanguage: String? = nil,
        options: TranscriptionOptions = .init(),
        sourceLabels: SourceLabels = .init(),
        preferredDeviceIDs: [String] = [],
        playbackMonitor: (any AudioPlaybackMonitoring)? = nil,
        echoCancellation: (any EchoCancellation)? = nil,
        audioFileDecoder: (any AudioFileDecoding)? = nil,
        recordingStore: RecordingStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        hostClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.deviceProvider = deviceProvider
        self.captureFactory = captureFactory
        self.engine = engine
        engine.languageDidChange(to: options.language)
        self.engineLanguage = options.language
        self.isModelDownloaded = engine.isDownloaded
        self.pipeline = NotePipeline(
            engine: engine,
            saver: NoteSaver(noteWriter: noteWriter, pendingNotes: pendingNotes),
            summarizer: summarizer,
            translator: translator,
            translationLanguage: translationLanguage,
            sourceLabels: sourceLabels,
            now: now
        )
        self.summaryTemplate = summaryTemplate
        self.callSummaryTemplate = callSummaryTemplate
        self.options = options
        self.preferredDeviceIDs = preferredDeviceIDs
        self.playbackMonitor = playbackMonitor
        self.echoCancellation = echoCancellation
        self.audioFileDecoder = audioFileDecoder
        self.recordingStore = recordingStore
        self.now = now
        self.hostClock = hostClock
        pipeline.didChangeStage = { [weak self] stage in self?.pipelineDidChange(to: stage) }
        pipeline.saver.didSaveAll = { [weak self] in self?.pendingNotesDidSave() }
        pipeline.saver.didSave = { note in
            if let id = note.recordingID { recordingStore?.delete(id) }
        }
        loadUnfinishedRecordings(except: Set(pendingNotes.compactMap(\.recordingID)))
        for (recording, audio) in recordingsInMemory.recordings {
            self.recordingsInMemory[recording.id] = audio
            keep(recording)
        }
    }

    // MARK: - Recording

    public func toggleRecording() async {
        if canStopRecording {
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
}
