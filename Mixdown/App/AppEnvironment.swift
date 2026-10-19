import AppKit
import KeyboardShortcuts
import MixdownAudio
import MixdownCore
import MixdownFoundationModels
import MixdownNotes
import MixdownSpeechSwift
import Observation

/// Composition root: wires concrete implementations into the `RecordingCoordinator` and keeps
/// app preferences in sync with it.
@MainActor @Observable
final class AppEnvironment {
    /// Replaced (never mutated in place) when the transcription model changes, because the coordinator
    /// receives its engine at init.
    private(set) var coordinator: RecordingCoordinator
    private(set) var model: TranscriptionModel
    /// Makes the summaries; `coordinator` only has it while summaries are on.
    let summarizer: any Summarizer
    let notesFolder: NotesFolderStore
    let noteTrash: NoteTrash
    private let noteReady: NoteReady
    /// Created at launch, as it handles buttons on notifications from an earlier run.
    private let notificationResponder: NotificationResponder

    /// Whole seconds recorded so far, advanced every second and held while paused; `nil` unless
    /// recording. Ticked here because the menu bar label only redraws on observed changes; it
    /// doesn't run `TimelineView` or `.task`.
    private(set) var recordingElapsed: Int?

    /// Whether to post notifications when calls start and end. See `CallPrompt`.
    private(set) var notifiesAboutCalls: Bool
    /// Whether to start and stop recording with calls, without asking. See `CallPrompt`.
    private(set) var recordsCallsAutomatically: Bool
    /// Whether the global shortcut (`KeyboardShortcuts.Name.toggleRecording`) starts and stops
    /// recording. Off, the shortcut is kept but released, so other apps get those keys.
    private(set) var isRecordingShortcutEnabled: Bool
    /// Whether a recording shows in the Dynamic Island rather than the menu bar. See `DynamicIsland`.
    private(set) var showsRecordingInDynamicIsland: Bool
    /// What the Dynamic Island shows, and where.
    private(set) var islandLayout: DynamicIsland.Layout
    /// Whether the Dynamic Island is showing the recording time where it can always be seen, so
    /// the menu bar leaves it out. See `DynamicIsland.showsTimeAlone`.
    private(set) var dynamicIslandShowsTimeAlone = false

    private let settings: AppSettings
    /// Shared by every coordinator, so the canceller it keeps loaded survives a model change.
    private static let echoCancellation = LocalVQEEchoCancellation()
    @ObservationIgnored private var deviceMonitor: Task<Void, Never>?
    @ObservationIgnored private var recordingClock: Task<Void, Never>?
    @ObservationIgnored private var recordingClockStart: Date?
    @ObservationIgnored private var callPrompt: CallPrompt?
    /// Created the first time it's shown.
    @ObservationIgnored private var dynamicIsland: DynamicIsland?
    /// Opens Record in the main window.
    private let showRecorder: () -> Void
    /// The note `observeNewNotes` announced last.
    @ObservationIgnored private var notifiedNoteURL: URL?
    /// The phase `observePhaseForCues` saw last.
    @ObservationIgnored private var cuedPhase: RecordingCoordinator.Phase = .idle

    init(navigation: MainNavigation, settings: AppSettings = AppSettings()) {
        let notesFolder = NotesFolderStore(settings: settings)
        let model = settings.transcriptionModel
        // This is the ONE place the summarizer is chosen. To use a different backend, construct
        // any other `Summarizer` here; nothing else changes.
        let summarizer: any Summarizer = AppleIntelligenceSummarizer()
        let noteTrash = NoteTrash()
        let noteReady = NoteReady(navigation: navigation)
        self.settings = settings
        self.model = model
        self.summarizer = summarizer
        self.notesFolder = notesFolder
        self.noteTrash = noteTrash
        self.noteReady = noteReady
        self.notificationResponder = NotificationResponder(noteTrash: noteTrash, noteReady: noteReady)
        self.coordinator = Self.makeCoordinator(
            model: model,
            summarizer: settings.summarizesNotes ? summarizer : nil,
            notesDirectory: notesFolder.directory,
            settings: settings
        )
        self.showRecorder = { [weak navigation] in
            guard let navigation, let openWindow = navigation.openWindow else { return }
            navigation.show(.recorder, using: openWindow)
        }
        self.notifiesAboutCalls = settings.notifiesAboutCalls
        self.recordsCallsAutomatically = settings.recordsCallsAutomatically
        self.isRecordingShortcutEnabled = settings.isRecordingShortcutEnabled
        self.showsRecordingInDynamicIsland = settings.showsRecordingInDynamicIsland
        self.islandLayout = settings.islandLayout

        startCoordinatorTasks()
        observeRecording()
        observeDynamicIsland()
        observePhaseForCues()
        observeNotesFolder()
        observeNewNotes()
        listenForRecordingShortcut()
        startCallPrompt()
    }

    // MARK: Composition

    private static func makeCoordinator(
        model: TranscriptionModel,
        summarizer: (any Summarizer)?,
        notesDirectory: URL?,
        pendingNotes: [Note] = [],
        settings: AppSettings
    ) -> RecordingCoordinator {
        let coordinator = RecordingCoordinator(
            deviceProvider: CoreAudioDeviceProvider(),
            captureFactory: DefaultAudioCaptureFactory(),
            // `TranscriptionModel.makeEngine()` is the ONE place the transcription engine is chosen.
            // To add a backend, give it a case there; nothing else here changes.
            engine: model.makeEngine(),
            noteWriter: notesDirectory.map { MarkdownNoteWriter(directory: $0) },
            pendingNotes: pendingNotes,
            summarizer: summarizer,
            summaryTemplate: settings.summaryTemplate,
            callSummaryTemplate: settings.callSummaryTemplate,
            options: TranscriptionOptions(language: settings.language),
            sourceLabels: settings.sourceLabels,
            preferredDeviceIDs: settings.selectedDeviceIDs,
            playbackMonitor: CoreAudioPlaybackMonitor(),
            echoCancellation: echoCancellation
        )
        coordinator.cancelsEcho = settings.cancelsEcho
        return coordinator
    }

    /// Starts what a new coordinator needs running: device monitoring, and checking whether the
    /// model is downloaded, for an engine that can only tell asynchronously. Device monitoring
    /// lives here rather than in a view's `.task`: menu-style `MenuBarExtra` content isn't
    /// guaranteed to be alive while the menu is closed.
    private func startCoordinatorTasks() {
        deviceMonitor?.cancel()
        deviceMonitor = Task { [coordinator] in
            await coordinator.monitorDevices()
        }
        Task { [coordinator] in
            await coordinator.refreshModelStatus()
        }
    }

    /// Watches for calls, to offer to record them or record them automatically.
    private func startCallPrompt() {
        let callPrompt = CallPrompt(
            isRecording: { [weak self] in self?.coordinator.canStopRecording ?? false },
            startRecording: { [weak self] in self?.startRecordingCall() ?? false },
            stopRecording: { [weak self] in self?.stopRecordingCall() },
            markRecordingAsCall: { [weak self] in self?.coordinator.markRecordingAsCall(automatically: $0) },
            showRecorder: showRecorder
        )
        callPrompt.notifies = notifiesAboutCalls
        callPrompt.recordsAutomatically = recordsCallsAutomatically
        notificationResponder.callPrompt = callPrompt
        self.callPrompt = callPrompt
    }

    // MARK: Observation
    //
    // Each `observe…` method reads what it depends on in `withObservationTracking`, acts on it, and
    // re-registers itself on the next change, as tracking only fires once. Those that read
    // `coordinator` also run again when it's replaced, by a new one that starts out idle and
    // without a note.

    /// Ticks `recordingElapsed` while recording and holds it while paused, and tells the call
    /// prompt when a recording starts and stops.
    private func observeRecording() {
        let phase = withObservationTracking {
            coordinator.phase
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeRecording() }
        }
        switch phase {
        case .startingCapture:
            // Neither started nor stopped yet; the call prompt is waiting for the recording to start.
            return
        case .paused(let recorded):
            // The same recording carries on, so the call prompt isn't told.
            stopRecordingClock()
            recordingElapsed = Int(recorded)
        case .recording(let startedAt):
            guard startedAt != recordingClockStart else { return }
            // Set while recording or paused, so resuming isn't taken for a new recording.
            if recordingElapsed == nil { callPrompt?.recordingDidStart() }
            startRecordingClock(from: startedAt)
        default:
            callPrompt?.recordingDidStop()
            stopRecordingClock()
            recordingElapsed = nil
        }
    }

    /// Ticks `recordingElapsed` every second from `startedAt`.
    private func startRecordingClock(from startedAt: Date) {
        recordingClock?.cancel()
        recordingClockStart = startedAt
        recordingElapsed = Int(max(Date.now.timeIntervalSince(startedAt), 0))
        recordingClock = Task { [weak self] in
            while !Task.isCancelled {
                let elapsed = max(Date.now.timeIntervalSince(startedAt), 0)
                self?.recordingElapsed = Int(elapsed)
                // Wake on the next whole second since the start, so the display doesn't lag.
                try? await Task.sleep(for: .seconds(1 - elapsed.truncatingRemainder(dividingBy: 1)))
            }
        }
    }

    private func stopRecordingClock() {
        recordingClock?.cancel()
        recordingClock = nil
        recordingClockStart = nil
    }

    /// Shows the Dynamic Island while recording, if it's turned on, and lays it out again when its
    /// settings change.
    private func observeDynamicIsland() {
        let (shows, layout) = withObservationTracking {
            (coordinator.isRecording && showsRecordingInDynamicIsland, islandLayout)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeDynamicIsland() }
        }
        if shows {
            let island =
                dynamicIsland
                ?? DynamicIsland(
                    environment: self,
                    openRecorder: showRecorder,
                    showsTimeAloneChanged: { [weak self] in self?.dynamicIslandShowsTimeAlone = $0 }
                )
            dynamicIsland = island
            island.show(layout)
        } else {
            dynamicIsland?.hide()
        }
    }

    /// Plays the audio cue for each phase change, such as recording starting.
    private func observePhaseForCues() {
        let phase = withObservationTracking {
            coordinator.phase
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePhaseForCues() }
        }
        defer { cuedPhase = phase }
        guard let cue = AudioCue.cue(from: cuedPhase, to: phase) else { return }
        AudioCues.play(cue, settings: settings)
    }

    /// Points the coordinator at the notes folder whenever it's chosen, goes away or comes back.
    /// Without one, recording is disabled.
    private func observeNotesFolder() {
        let directory = withObservationTracking {
            notesFolder.directory
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeNotesFolder() }
        }
        coordinator.noteWriter = directory.map { MarkdownNoteWriter(directory: $0) }
    }

    /// Posts "Note Ready", and plays its cue, for every note the coordinator writes.
    private func observeNewNotes() {
        let url = withObservationTracking {
            coordinator.lastNoteURL
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeNewNotes() }
        }
        guard let url, url != notifiedNoteURL else { return }
        notifiedNoteURL = url
        AudioCues.play(.noteReady, settings: settings)
        Task { await noteReady.notify(noteAt: url) }
    }

    // MARK: Input

    /// The selected microphone, if any. The menu and settings offer one microphone at a time, plus
    /// system audio on top.
    var selectedMicrophone: AudioInputDevice? {
        coordinator.selectedDevices.first { $0.kind == .microphone }
    }

    var recordsSystemAudio: Bool {
        coordinator.selectedDevices.contains { $0.kind == .systemAudio }
    }

    /// Whether the microphone is **System Default**, following the Mac's default input.
    var followsDefaultMicrophone: Bool {
        coordinator.followsDefaultMicrophone && selectedMicrophone != nil
    }

    /// The microphone as chosen: `AudioInputDevice.defaultMicrophone` for System Default, else
    /// the selected device.
    private var chosenMicrophone: AudioInputDevice? {
        followsDefaultMicrophone ? .defaultMicrophone : selectedMicrophone
    }

    /// Switches to `device` (replacing the current microphone) or, with `nil`, records without a
    /// microphone. `AudioInputDevice.defaultMicrophone` follows the Mac's default input. Ignored if
    /// that would leave no input selected.
    func selectMicrophone(_ device: AudioInputDevice?) {
        var selection = coordinator.selectedDevices.filter { $0.kind != .microphone }
        if let device { selection.insert(device, at: 0) }
        applySelection(selection)
    }

    /// Adds or removes system audio. Ignored if that would leave no input selected.
    func setRecordsSystemAudio(_ enabled: Bool) {
        var selection = chosenMicrophone.map { [$0] } ?? []
        if enabled, let systemAudio = coordinator.devices.first(where: { $0.kind == .systemAudio }) {
            selection.append(systemAudio)
        }
        applySelection(selection)
    }

    /// Selects devices and remembers them as the user's preference.
    private func applySelection(_ selection: [AudioInputDevice]) {
        guard coordinator.selectDevices(selection) else { return }
        settings.selectedDeviceIDs = selection.map(\.id)
    }

    /// Whether to take the system audio's echo out of the microphone. Takes effect from the next
    /// recording.
    var cancelsEcho: Bool {
        get { coordinator.cancelsEcho }
        set {
            settings.cancelsEcho = newValue
            coordinator.cancelsEcho = newValue
        }
    }

    /// Speaker names for multi-source recordings. Takes effect from the next transcription.
    var sourceLabels: SourceLabels {
        get { coordinator.sourceLabels }
        set {
            settings.sourceLabels = newValue
            coordinator.sourceLabels = newValue
        }
    }

    // MARK: Calls

    func setNotifiesAboutCalls(_ enabled: Bool) {
        settings.notifiesAboutCalls = enabled
        notifiesAboutCalls = enabled
        callPrompt?.notifies = enabled
    }

    func setRecordsCallsAutomatically(_ enabled: Bool) {
        settings.recordsCallsAutomatically = enabled
        recordsCallsAutomatically = enabled
        callPrompt?.recordsAutomatically = enabled
    }

    /// Starts recording a call: with system audio on, so the other people are recorded too, and the
    /// microphone if one is selected. Returns `false` if recording can't start, e.g. as the model
    /// isn't downloaded; Record in the main window says why.
    private func startRecordingCall() -> Bool {
        guard !coordinator.canStopRecording else { return true }
        setRecordsSystemAudio(true)
        guard coordinator.canStartRecording else { return false }
        Task { await coordinator.startRecording() }
        return true
    }

    /// Stops recording, as the call has ended.
    private func stopRecordingCall() {
        guard coordinator.canStopRecording else { return }
        Task { await coordinator.stopRecording() }
    }

    // MARK: Global shortcut

    /// Starts or stops recording on the global shortcut, from any app. While busy downloading,
    /// transcribing or summarizing, it beeps, as recording can start once that's done. When
    /// recording can't start for something the user has to do (no notes folder, model or input),
    /// it opens Record instead, which says what.
    private func listenForRecordingShortcut() {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            guard let self else { return }
            let coordinator = self.coordinator
            if coordinator.canStopRecording || coordinator.canStartRecording {
                Task { await coordinator.toggleRecording() }
            } else if !coordinator.isIdle {
                NSSound.beep()
            } else {
                self.showRecorder()
            }
        }
        if !isRecordingShortcutEnabled {
            KeyboardShortcuts.disable(.toggleRecording)
        }
    }

    func setRecordingShortcutEnabled(_ enabled: Bool) {
        settings.isRecordingShortcutEnabled = enabled
        isRecordingShortcutEnabled = enabled
        if enabled {
            KeyboardShortcuts.enable(.toggleRecording)
        } else {
            KeyboardShortcuts.disable(.toggleRecording)
        }
    }

    // MARK: Design

    func setShowsRecordingInDynamicIsland(_ enabled: Bool) {
        settings.showsRecordingInDynamicIsland = enabled
        showsRecordingInDynamicIsland = enabled
    }

    func setIslandLayout(_ layout: DynamicIsland.Layout) {
        settings.islandLayout = layout
        islandLayout = layout
    }

    // MARK: Transcription

    var language: String? { coordinator.options.language }

    func setLanguage(_ language: String?) {
        settings.language = language
        coordinator.options.language = language
    }

    /// Whether the coordinator can be replaced: nothing is recording, starting, downloading,
    /// transcribing or saving.
    var canChangeModel: Bool { coordinator.isIdle && !coordinator.isSavingPendingNotes }

    /// Switches models by rebuilding the coordinator. Ignored unless `canChangeModel`; the
    /// settings UI disables the picker in that case.
    func setModel(_ model: TranscriptionModel) {
        guard model != self.model, canChangeModel else { return }
        settings.transcriptionModel = model
        self.model = model
        coordinator = Self.makeCoordinator(
            model: model,
            summarizer: coordinator.summarizer,
            notesDirectory: notesFolder.directory,
            pendingNotes: coordinator.takePendingNotes(),
            settings: settings
        )
        startCoordinatorTasks()
    }

    // MARK: Summary

    /// Whether notes get a summary. Takes effect from the next recording, even if the summarizer
    /// is unavailable right now; it's skipped until it becomes available.
    var summarizesNotes: Bool {
        get { coordinator.summarizer != nil }
        set {
            settings.summarizesNotes = newValue
            coordinator.summarizer = newValue ? summarizer : nil
        }
    }

    /// The summary template for recordings started by hand. Takes effect from the next summary.
    var summaryTemplate: SummaryTemplate {
        get { coordinator.summaryTemplate }
        set {
            settings.summaryTemplate = newValue
            coordinator.summaryTemplate = newValue
        }
    }

    /// The summary template for recordings started for a call, from the call notification or
    /// automatically. Takes effect from the next summary.
    var callSummaryTemplate: SummaryTemplate {
        get { coordinator.callSummaryTemplate }
        set {
            settings.callSummaryTemplate = newValue
            coordinator.callSummaryTemplate = newValue
        }
    }

    // MARK: Notes

    func chooseNotesFolder() {
        notesFolder.chooseFolder()
    }

    func openNotesFolder() {
        guard let directory = notesFolder.directory else { return }
        NSWorkspace.shared.open(directory)
    }

    func revealLastNote() {
        guard let url = coordinator.lastNoteURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
