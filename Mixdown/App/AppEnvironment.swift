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

    private let settings: AppSettings
    @ObservationIgnored private var deviceMonitor: Task<Void, Never>?

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
        startMonitoringDevices()
    }

    // MARK: Composition

    private static func makeCoordinator(
        model: SpeechSwiftModel,
        notesDirectory: URL,
        settings: AppSettings
    ) -> RecordingCoordinator {
        RecordingCoordinator(
            deviceProvider: CoreAudioDeviceProvider(),
            captureFactory: DefaultAudioCaptureFactory(),
            // This is the ONE place the transcription engine is chosen. To use a different
            // backend, construct any other `TranscriptionEngine` here; nothing else changes.
            engine: SpeechSwiftEngine(model: model),
            noteWriter: MarkdownNoteWriter(directory: notesDirectory),
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
        if notesFolder.chooseFolder() { applyNotesFolder() }
    }

    func resetNotesFolder() {
        notesFolder.resetToDefault()
        applyNotesFolder()
    }

    func openNotesFolder() {
        let directory = notesFolder.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    func revealLastNote() {
        guard let url = coordinator.lastNoteURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func applyNotesFolder() {
        coordinator.noteWriter = MarkdownNoteWriter(directory: notesFolder.directory)
    }
}
