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
    private(set) var model: SpeechSwiftModel
    /// Makes the summaries; `coordinator` only has it while summaries are on.
    let summarizer: any Summarizer
    let notesFolder: NotesFolderStore
    let noteTrash: NoteTrash
    private let noteReady: NoteReady
    /// Created at launch, as it handles buttons on notifications from an earlier run.
    private let notificationResponder: NotificationResponder

    /// Whole seconds since the current recording started, advanced every second; `nil` unless
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

    private let settings: AppSettings
    @ObservationIgnored private var deviceMonitor: Task<Void, Never>?
    @ObservationIgnored private var recordingClock: Task<Void, Never>?
    @ObservationIgnored private var recordingClockStart: Date?
    @ObservationIgnored private var callPrompt: CallPrompt?
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
        self.summarizer = summarizer
        self.notesFolder = notesFolder
        self.model = model
        self.noteTrash = noteTrash
        self.noteReady = noteReady
        self.isRecordingShortcutEnabled = settings.isRecordingShortcutEnabled
        self.notificationResponder = NotificationResponder(noteTrash: noteTrash, noteReady: noteReady)
        self.coordinator = Self.makeCoordinator(
            model: model,
            summarizer: settings.summarizesNotes ? summarizer : nil,
            notesDirectory: notesFolder.directory,
            settings: settings
        )
        self.notifiesAboutCalls = settings.notifiesAboutCalls
        self.recordsCallsAutomatically = settings.recordsCallsAutomatically
        startMonitoringDevices()
        observeRecording()
        observePhaseForCues()
        observeNotesFolder()
        observeNewNotes()
        listenForRecordingShortcut(navigation: navigation)
        let callPrompt = CallPrompt(
            isRecording: { [weak self] in self?.coordinator.isRecording ?? false },
            startRecording: { [weak self] in self?.startRecordingCall() ?? false },
            stopRecording: { [weak self] in self?.stopRecordingCall() },
            markRecordingAsCall: { [weak self] in self?.coordinator.markRecordingAsCall() },
            showRecorder: { [weak navigation] in
                guard let navigation, let openWindow = navigation.openWindow else { return }
                navigation.show(.recorder, using: openWindow)
            }
        )
        callPrompt.notifies = notifiesAboutCalls
        callPrompt.recordsAutomatically = recordsCallsAutomatically
        notificationResponder.callPrompt = callPrompt
        self.callPrompt = callPrompt
    }

    // MARK: Composition

    private static func makeCoordinator(
        model: SpeechSwiftModel,
        summarizer: (any Summarizer)?,
        notesDirectory: URL?,
        settings: AppSettings
    ) -> RecordingCoordinator {
        RecordingCoordinator(
            deviceProvider: CoreAudioDeviceProvider(),
            captureFactory: DefaultAudioCaptureFactory(),
            // This is the ONE place the transcription engine is chosen. To use a different
            // backend, construct any other `TranscriptionEngine` here; nothing else changes.
            engine: SpeechSwiftEngine(model: model),
            noteWriter: notesDirectory.map { MarkdownNoteWriter(directory: $0) },
            summarizer: summarizer,
            options: TranscriptionOptions(language: settings.language),
            sourceLabels: settings.sourceLabels,
            preferredDeviceIDs: settings.selectedDeviceIDs,
            playbackMonitor: CoreAudioPlaybackMonitor()
        )
    }

    /// Device monitoring lives here rather than in a view's `.task`: menu-style
    /// `MenuBarExtra` content isn't guaranteed to be alive while the menu is closed.
    private func startMonitoringDevices() {
        deviceMonitor?.cancel()
        deviceMonitor = Task { [coordinator] in
            await coordinator.monitorDevices()
        }
    }

    /// Starts or stops `recordingClock` as the phase changes. Re-registers itself after every
    /// change, including the coordinator being replaced.
    private func observeRecording() {
        let phase = withObservationTracking {
            coordinator.phase
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeRecording() }
        }
        guard case .recording(let startedAt) = phase else {
            callPrompt?.recordingDidStop()
            recordingClock?.cancel()
            recordingClock = nil
            recordingClockStart = nil
            recordingElapsed = nil
            return
        }
        guard startedAt != recordingClockStart else { return }
        callPrompt?.recordingDidStart()
        recordingClock?.cancel()
        recordingClockStart = startedAt
        recordingClock = Task { [weak self] in
            while !Task.isCancelled {
                let elapsed = max(Date.now.timeIntervalSince(startedAt), 0)
                self?.recordingElapsed = Int(elapsed)
                // Wake on the next whole second since the start, so the display doesn't lag.
                try? await Task.sleep(for: .seconds(1 - elapsed.truncatingRemainder(dividingBy: 1)))
            }
        }
    }

    /// Plays the audio cue for each phase change, such as recording starting. Re-registers itself
    /// after every change, including the coordinator being replaced, which starts out idle.
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
    /// Without one, recording is disabled. Re-registers itself after every change.
    private func observeNotesFolder() {
        let directory = withObservationTracking {
            notesFolder.directory
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeNotesFolder() }
        }
        coordinator.noteWriter = directory.map { MarkdownNoteWriter(directory: $0) }
    }

    /// Posts "Note Ready", and plays its cue, for every note the coordinator writes. Re-registers
    /// itself after every change, including the coordinator being replaced, which starts out
    /// without a note.
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
        guard !coordinator.isRecording else { return true }
        setRecordsSystemAudio(true)
        guard coordinator.canStartRecording else { return false }
        Task { await coordinator.startRecording() }
        return true
    }

    /// Stops recording, as the call has ended.
    private func stopRecordingCall() {
        guard coordinator.isRecording else { return }
        Task { await coordinator.stopRecording() }
    }

    // MARK: Global shortcut

    /// Starts or stops recording on the global shortcut, from any app. When recording can't start
    /// yet (no notes folder or model, or busy transcribing), it opens Record instead, which says why.
    private func listenForRecordingShortcut(navigation: MainNavigation) {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            guard let self else { return }
            let coordinator = self.coordinator
            if coordinator.isRecording || coordinator.canStartRecording {
                Task { await coordinator.toggleRecording() }
            } else if let openWindow = navigation.openWindow {
                navigation.show(.recorder, using: openWindow)
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

    // MARK: Transcription

    var language: String? { coordinator.options.language }

    func setLanguage(_ language: String?) {
        settings.language = language
        coordinator.options.language = language
    }

    /// Whether the coordinator can be replaced: nothing is recording, starting, downloading or
    /// transcribing.
    var canChangeModel: Bool { coordinator.isIdle }

    /// Switches models by rebuilding the coordinator. Ignored unless `canChangeModel`; the
    /// settings UI disables the picker in that case.
    func setModel(_ model: SpeechSwiftModel) {
        guard model != self.model, canChangeModel else { return }
        settings.transcriptionModel = model
        self.model = model
        coordinator = Self.makeCoordinator(
            model: model,
            summarizer: coordinator.summarizer,
            notesDirectory: notesFolder.directory,
            settings: settings
        )
        startMonitoringDevices()
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
