import AppKit
import MixdownAudio
import MixdownCore
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
    let notesFolder: NotesFolderStore
    /// Created at launch, as it handles Restore on notifications from an earlier run.
    let noteTrash = NoteTrash()
    /// Opens the main window at Record. Set by `MainView`, which opens at launch, as only views
    /// can open windows.
    @ObservationIgnored var showRecorder: (() -> Void)?

    /// Whole seconds since the current recording started, advanced every second; `nil` unless
    /// recording. Ticked here because the menu bar label only redraws on observed changes; it
    /// doesn't run `TimelineView` or `.task`.
    private(set) var recordingElapsed: Int?

    /// Whether to offer recording when a call starts. See `MeetingPrompt`.
    private(set) var asksToRecordMeetings: Bool

    private let settings: AppSettings
    @ObservationIgnored private var deviceMonitor: Task<Void, Never>?
    @ObservationIgnored private var recordingClock: Task<Void, Never>?
    @ObservationIgnored private var recordingClockStart: Date?
    @ObservationIgnored private var meetingPrompt: MeetingPrompt?

    init(settings: AppSettings = AppSettings()) {
        let notesFolder = NotesFolderStore(settings: settings)
        let model = settings.transcriptionModel
        self.settings = settings
        self.notesFolder = notesFolder
        self.model = model
        self.coordinator = Self.makeCoordinator(
            model: model,
            notesDirectory: notesFolder.directory,
            settings: settings
        )
        self.asksToRecordMeetings = settings.asksToRecordMeetings
        startMonitoringDevices()
        observeRecording()
        observeNotesFolder()
        let meetingPrompt = MeetingPrompt(
            isRecording: { [weak self] in self?.coordinator.isRecording ?? false },
            onRecord: { [weak self] in self?.recordMeeting() }
        )
        meetingPrompt.isEnabled = asksToRecordMeetings
        self.meetingPrompt = meetingPrompt
    }

    // MARK: Composition

    private static func makeCoordinator(
        model: SpeechSwiftModel,
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
            options: TranscriptionOptions(language: settings.language),
            sourceLabels: settings.sourceLabels,
            preferredDeviceIDs: settings.selectedDeviceIDs
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
            recordingClock?.cancel()
            recordingClock = nil
            recordingClockStart = nil
            recordingElapsed = nil
            return
        }
        guard startedAt != recordingClockStart else { return }
        meetingPrompt?.withdrawPrompts()
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

    // MARK: Input

    /// The selected microphone, if any. The menu and settings offer one microphone at a time, plus
    /// system audio on top.
    var selectedMicrophone: AudioInputDevice? {
        coordinator.selectedDevices.first { $0.kind == .microphone }
    }

    var recordsSystemAudio: Bool {
        coordinator.selectedDevices.contains { $0.kind == .systemAudio }
    }

    /// Switches to `device` (replacing the current microphone) or, with `nil`, records without a
    /// microphone. Ignored if that would leave no input selected.
    func selectMicrophone(_ device: AudioInputDevice?) {
        var selection = coordinator.selectedDevices.filter { $0.kind != .microphone }
        if let device { selection.insert(device, at: 0) }
        applySelection(selection)
    }

    /// Adds or removes system audio. Ignored if that would leave no input selected.
    func setRecordsSystemAudio(_ enabled: Bool) {
        var selection = coordinator.selectedDevices.filter { $0.kind != .systemAudio }
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

    // MARK: Meetings

    func setAsksToRecordMeetings(_ enabled: Bool) {
        settings.asksToRecordMeetings = enabled
        asksToRecordMeetings = enabled
        meetingPrompt?.isEnabled = enabled
    }

    /// Records a call from the meeting notification: with system audio on, so the other people
    /// are recorded too, and the microphone if one is selected. When recording can't start, e.g.
    /// as the model isn't downloaded, opens Record instead, which says why.
    private func recordMeeting() {
        guard !coordinator.isRecording else { return }
        setRecordsSystemAudio(true)
        guard coordinator.canStartRecording else {
            showRecorder?()
            return
        }
        Task { await coordinator.startRecording() }
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
            notesDirectory: notesFolder.directory,
            settings: settings
        )
        startMonitoringDevices()
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
