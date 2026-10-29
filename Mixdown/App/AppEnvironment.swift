import AppKit
import KeyboardShortcuts
import MixdownAppleTranslation
import MixdownAudio
import MixdownCore
import MixdownFoundationModels
import MixdownMLXLLM
import MixdownNaturalLanguage
import MixdownNotes
import MixdownSpeechSwift
import Observation
import UniformTypeIdentifiers

/// Composition root: wires concrete implementations into the `RecordingCoordinator` and hands it
/// the user's `preferences`.
@MainActor @Observable
final class AppEnvironment {
    /// Replaced (never mutated in place) when the transcription model changes, because the coordinator
    /// receives its engine at init.
    private(set) var coordinator: RecordingCoordinator
    private(set) var model: TranscriptionModel
    /// The model summaries and catch-ups are made with.
    private(set) var summaryModel: SummaryModel
    /// Makes the summaries and catch-ups with `summaryModel`; `coordinator` only has it while
    /// summaries are on. Replaced when the model changes.
    private(set) var summarizer: any Summarizer
    /// Downloads `summaryModel`; `nil` for one macOS provides.
    private(set) var summaryModelDownload: ModelDownload?
    /// Downloads the model that tells speakers apart. A recording that ends without it downloads
    /// it then.
    let speakerModelDownload: ModelDownload
    /// Translates transcripts, into the coordinator's `translationLanguage` when there is one.
    let translator: any Translator
    /// The user's preferences, which views change directly. `applyPreferences()` hands them on.
    let preferences: Preferences
    /// The Dynamic Island, and the moment field and Catch Me Up card under the notch.
    let island = IslandController()
    /// Checks for and installs new releases; does nothing in builds from source.
    let updater = Updater()
    let notesFolder: NotesFolderStore
    /// The notes in `notesFolder`, read and watched for as long as the app runs, for the main
    /// window, Chat and Spotlight alike.
    let library: NoteLibraryModel
    let noteTrash: NoteTrash
    /// Searching, selecting, renaming and trashing the notes in the main window.
    let noteBrowser: NoteBrowserModel
    /// Chat across the notes, kept while the main window is closed.
    let noteChat: NoteChat
    private let noteReady: NoteReady
    private let noteSpotlight = NoteSpotlight()
    /// Created at launch, as it handles buttons on notifications from an earlier run.
    private let notificationResponder: NotificationResponder

    /// Whole seconds recorded so far, advanced every second and held while paused; `nil` unless
    /// recording. Ticked here because the menu bar label only redraws on observed changes; it
    /// doesn't run `TimelineView` or `.task`.
    private(set) var recordingElapsed: Int?

    private let settings: AppSettings
    /// Shared by every coordinator, so the canceller it keeps loaded survives a model change.
    private static let echoCancellation = LocalVQEEchoCancellation()
    /// Tells speakers apart once a recording ends, while `Preferences.identifiesSpeakers`. Shared
    /// by every coordinator, like `echoCancellation`.
    private static let speakerDiarizer = NemotronSpeakerDiarizer()
    @ObservationIgnored private var deviceMonitor: Task<Void, Never>?
    /// Reads `library`'s folder again whenever its files change.
    @ObservationIgnored private var libraryWatch: (directory: URL?, task: Task<Void, Never>)?
    @ObservationIgnored private var recordingClock: Task<Void, Never>?
    @ObservationIgnored private var recordingClockStart: Date?
    @ObservationIgnored private var callPrompt: CallPrompt?
    @ObservationIgnored private var stillRecordingPrompt: StillRecordingPrompt?
    /// What the main window shows. Kept by the app.
    @ObservationIgnored private weak var navigation: MainNavigation?
    /// Opens Record in the main window.
    private let showRecorder: () -> Void
    /// Switches the main window from Chat to the notes, if it's showing Chat.
    private let leaveChat: () -> Void
    /// The note `observeNewNotes` announced last.
    @ObservationIgnored private var notifiedNoteURL: URL?
    /// The phase `observePhaseForCues` saw last.
    @ObservationIgnored private var cuedPhase: RecordingCoordinator.Phase = .idle

    init(navigation: MainNavigation, settings: AppSettings = AppSettings()) {
        let notesFolder = NotesFolderStore(settings: settings)
        let preferences = Preferences(settings: settings)
        let model = settings.transcriptionModel
        // `SummaryModel.makeSummarizer()` is the ONE place the summarizer is chosen. To add a
        // backend, give it a case there; nothing else here changes.
        let summaryModel = settings.summaryModel
        let summarizer = summaryModel.makeSummarizer()
        // Likewise the ONE place the translator is chosen.
        let translator: any Translator = AppleTranslator()
        let noteTrash = NoteTrash()
        let noteReady = NoteReady(navigation: navigation)
        let library = NoteLibraryModel()
        // Likewise the ONE place Chat's model and embeddings are chosen.
        self.noteChat = NoteChat(
            answerer: AppleIntelligenceAnswerer(),
            embedder: NaturalLanguageEmbedder(),
            indexDirectory: URL.applicationSupportDirectory.appending(path: "ChatIndex", directoryHint: .isDirectory),
            legacyIndexFile: URL.applicationSupportDirectory.appending(path: "ChatIndex.plist")
        )
        self.settings = settings
        self.preferences = preferences
        self.model = model
        self.summaryModel = summaryModel
        self.summarizer = summarizer
        self.summaryModelDownload = Self.makeDownload(for: summarizer)
        self.speakerModelDownload = Self.makeSpeakerModelDownload()
        self.translator = translator
        self.notesFolder = notesFolder
        self.library = library
        self.noteTrash = noteTrash
        self.noteBrowser = NoteBrowserModel(
            library: library,
            notesFolder: notesFolder,
            noteTrash: noteTrash,
            navigation: navigation
        )
        self.noteReady = noteReady
        self.notificationResponder = NotificationResponder(noteTrash: noteTrash, noteReady: noteReady)
        self.coordinator = Self.makeCoordinator(
            model: model,
            summarizer: summarizer,
            translator: translator,
            noteWriter: notesFolder.noteWriter,
            preferredDeviceIDs: settings.selectedDeviceIDs,
            preferences: preferences
        )
        self.navigation = navigation
        self.showRecorder = { [weak navigation] in
            guard let navigation, let openWindow = navigation.openWindow else { return }
            navigation.show(.recorder, using: openWindow)
        }
        self.leaveChat = { [weak navigation] in
            if navigation?.destination == .chat { navigation?.destination = .notes }
        }

        startCoordinatorTasks()
        observeRecording()
        observePhaseForCues()
        observeNotesFolder()
        observeSpotlight()
        observeNewNotes()
        listenForRecordingShortcut()
        startCallPrompt()
        updater.isBusy = { [weak self] in
            guard let coordinator = self?.coordinator else { return false }
            return coordinator.isRecording || coordinator.isMakingNote
        }
        startStillRecordingPrompt()
        island.start(environment: self, openRecorder: showRecorder)
        preferences.didChange = { [weak self] in self?.applyPreferences() }
        applyPreferences()
    }

    // MARK: Composition

    private static func makeCoordinator(
        model: TranscriptionModel,
        summarizer: any Summarizer,
        translator: any Translator,
        noteWriter: (any NoteWriting)?,
        pendingNotes: [Note] = [],
        recordingsInMemory: RecordingsInMemory = RecordingsInMemory(),
        preferredDeviceIDs: [String],
        preferences: Preferences
    ) -> RecordingCoordinator {
        let coordinator = RecordingCoordinator(
            deviceProvider: CoreAudioDeviceProvider(),
            captureFactory: DefaultAudioCaptureFactory(),
            // `TranscriptionModel.makeEngine()` is the ONE place the transcription engine is chosen.
            // To add a backend, give it a case there; nothing else here changes.
            engine: model.makeEngine(),
            noteWriter: noteWriter,
            pendingNotes: pendingNotes,
            recordingsInMemory: recordingsInMemory,
            summarizer: nil,
            summaryTemplate: preferences.summaryTemplates.recordingTemplate,
            callSummaryTemplate: preferences.summaryTemplates.callTemplate,
            translator: translator,
            translationLanguage: nil,
            options: TranscriptionOptions(language: preferences.language),
            sourceLabels: preferences.sourceLabels,
            preferredDeviceIDs: preferredDeviceIDs,
            playbackMonitor: CoreAudioPlaybackMonitor(),
            echoCancellation: echoCancellation,
            audioFileDecoder: AudioFileDecoder(),
            recordingStore: .default
        )
        coordinator.apply(preferences.coordinatorSettings, summarizer: summarizer, diarizer: speakerDiarizer)
        return coordinator
    }

    /// Hands the preferences to the coordinator, the call prompt and the recording shortcut. Runs
    /// whenever one changes.
    private func applyPreferences() {
        coordinator.apply(preferences.coordinatorSettings, summarizer: summarizer, diarizer: Self.speakerDiarizer)
        if let callPrompt {
            callPrompt.apps = preferences.callApps.apps
            callPrompt.notifies = preferences.notifiesAboutCalls && preferences.showsNotifications
            if callPrompt.recordsAutomatically != preferences.recordsCallsAutomatically {
                callPrompt.recordsAutomatically = preferences.recordsCallsAutomatically
            }
        }
        if preferences.isRecordingShortcutEnabled {
            KeyboardShortcuts.enable(.toggleRecording)
        } else {
            KeyboardShortcuts.disable(.toggleRecording)
        }
    }

    /// A download for `summarizer`'s model, if Mixdown downloads it.
    private static func makeDownload(for summarizer: any Summarizer) -> ModelDownload? {
        guard let summarizer = summarizer as? MLXSummarizer else { return nil }
        return ModelDownload(
            name: summarizer.model.displayName,
            isDownloaded: { summarizer.isDownloaded },
            download: { try await summarizer.download(progress: $0) },
            delete: { try await summarizer.deleteModel() }
        )
    }

    private static func makeSpeakerModelDownload() -> ModelDownload {
        let diarizer = speakerDiarizer
        return ModelDownload(
            name: "the speaker model",
            isDownloaded: { diarizer.isDownloaded },
            download: { try await diarizer.prepare(progress: $0) },
            delete: { try await diarizer.deleteModel() }
        )
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

    /// Watches for calls, to offer to record them or record them automatically. Told what to do by
    /// `applyPreferences()`.
    private func startCallPrompt() {
        let callPrompt = CallPrompt(
            isRecording: { [weak self] in self?.coordinator.canStopRecording ?? false },
            timeSinceSpeech: { [weak self] in self?.coordinator.timeSinceSpeech },
            startRecording: { [weak self] in self?.startRecordingCall() ?? false },
            stopRecording: { [weak self] in self?.stopRecordingCall() },
            markRecordingAsCall: { [weak self] in self?.coordinator.markRecordingAsCall(in: $0, automatically: $1) },
            showRecorder: showRecorder
        )
        notificationResponder.callPrompt = callPrompt
        self.callPrompt = callPrompt
    }

    /// Asks whether to go on recording after a while without speech.
    private func startStillRecordingPrompt() {
        let prompt = StillRecordingPrompt(
            coordinator: { [weak self] in self?.coordinator },
            showRecorder: showRecorder
        )
        notificationResponder.stillRecordingPrompt = prompt
        stillRecordingPrompt = prompt
        observeStillRecording()
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

    /// Posts "Still Recording?" while the coordinator asks, and takes it away once answered.
    private func observeStillRecording() {
        let isAsking = withObservationTracking {
            coordinator.isAskingIfStillRecording
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStillRecording() }
        }
        if isAsking {
            stillRecordingPrompt?.ask()
        } else {
            stillRecordingPrompt?.withdraw()
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

    /// Points the coordinator and `library` at the notes folder whenever it's chosen, goes away or
    /// comes back. Without one, recording is disabled.
    private func observeNotesFolder() {
        let directory = withObservationTracking {
            notesFolder.directory
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeNotesFolder() }
        }
        coordinator.noteWriter = notesFolder.noteWriter
        watchLibrary(in: directory)
    }

    /// Reads the notes in `directory` into `library`, and again whenever its files change, until
    /// it's called with another folder.
    private func watchLibrary(in directory: URL?) {
        if let libraryWatch {
            guard libraryWatch.directory != directory else { return }
            libraryWatch.task.cancel()
        }
        let task = Task { [library, notesFolder] in
            // Started first, so nothing that changes during the first reload is missed.
            let changes = directory.map { NotesFolderWatcher.changes(in: $0) }
            await library.reload(from: directory)
            guard let changes else { return }
            for await change in changes {
                // The folder was renamed or moved, which the app doesn't otherwise notice until
                // it's next in front. `refresh()` finds it again, and `observeNotesFolder()`
                // watches it there.
                if change == .rootChanged {
                    notesFolder.refresh()
                    guard notesFolder.directory == directory else { return }
                }
                await library.reload(from: directory)
            }
        }
        libraryWatch = (directory, task)
    }

    /// Hands Spotlight the notes whenever they change, and adds or removes them as the preference
    /// is turned on or off.
    private func observeSpotlight() {
        let (notes, isEnabled) = withObservationTracking {
            // Without following the notes while it's off, so they aren't taken out on every change.
            preferences.indexesNotesInSpotlight ? (library.folder.map { _ in library.notes }, true) : (nil, false)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSpotlight() }
        }
        noteSpotlight.update(notes: notes, isEnabled: isEnabled)
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
        // Making the note may have downloaded the speaker or summary model.
        refreshModelDownloads()
        AudioCues.play(.noteReady, settings: settings)
        Task { await noteReady.notify(noteAt: url, in: library.notes) }
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

    // MARK: Speakers

    /// Turns telling apart the people on the system audio on or off. Turning it on downloads the
    /// model if it isn't on disk; turning it off stops a download.
    func setIdentifiesSpeakers(_ enabled: Bool) {
        preferences.identifiesSpeakers = enabled
        if enabled, !speakerModelDownload.isDownloaded { speakerModelDownload.start() }
        if !enabled { speakerModelDownload.cancel() }
    }

    /// Removes the speaker model's files. Turns telling speakers apart off, as it would only
    /// download them again.
    func deleteSpeakerModel() async {
        setIdentifiesSpeakers(false)
        await speakerModelDownload.delete()
    }

    // MARK: Calls

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

    /// Starts or stops recording on the global shortcut, from any app, like `mixdown://toggle`.
    /// `applyPreferences()` turns it on or off.
    private func listenForRecordingShortcut() {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.perform(.toggleRecording)
        }
    }

    // MARK: Links

    /// Does what a `mixdown://` link asks, for Raycast, Stream Deck, Keyboard Maestro and the like:
    /// whatever `RecordingCoordinator.action(for:)` makes of it now.
    func perform(_ command: URLCommand) {
        let coordinator = coordinator
        switch coordinator.action(for: command) {
        case .startRecording: Task { await coordinator.startRecording() }
        case .stopRecording: Task { await coordinator.stopRecording() }
        case .pauseRecording: Task { await coordinator.pauseRecording() }
        case .resumeRecording: Task { await coordinator.resumeRecording() }
        case .togglePause: Task { await coordinator.togglePause() }
        case .beep: NSSound.beep()
        case .showRecorder: showRecorder()
        case .markMoment: island.markMoment()
        case .addMoment(let time, let text): coordinator.addMoment(at: time, text: text)
        case .showMainWindow: showMainWindow()
        case .openNote(let reference): Task { await openNote(reference) }
        case .nothing: break
        }
    }

    /// Opens the note `reference` names (see `NoteLibrary.note(for:in:directory:)`), reading the
    /// notes folder again first if it isn't among the notes read so far: at launch, or just
    /// written. Without such a note, it beeps and opens Notes.
    private func openNote(_ reference: String) async {
        func find() -> NoteDocument? {
            guard let directory = library.folder else { return nil }
            return NoteLibrary.note(for: reference, in: library.notes, directory: directory)
        }
        var note = find()
        if note == nil {
            await library.reload(from: notesFolder.directory)
            note = find()
        }
        if let note {
            navigation?.showNote(at: note.url)
        } else {
            NSSound.beep()
            showMainWindow(at: .notes)
        }
    }

    /// Brings the main window forward, at `destination` or where it was.
    private func showMainWindow(at destination: MainNavigation.Destination? = nil) {
        guard let navigation, let openWindow = navigation.openWindow else { return }
        navigation.show(destination ?? navigation.destination, using: openWindow)
    }

    // MARK: Transcription

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
            summarizer: summarizer,
            translator: translator,
            noteWriter: notesFolder.noteWriter,
            pendingNotes: coordinator.takePendingNotes(),
            recordingsInMemory: coordinator.takeRecordingsInMemory(),
            preferredDeviceIDs: settings.selectedDeviceIDs,
            preferences: preferences
        )
        startCoordinatorTasks()
    }

    // MARK: Summary

    /// Whether `summaryModel` is on disk; always true for one macOS provides.
    var isSummaryModelDownloaded: Bool { summaryModelDownload?.isDownloaded ?? true }

    /// Marks the setup assistant as done, so it doesn't open again at the next launch.
    func finishSetup() {
        settings.needsSetup = false
    }

    /// Checks again whether the speaker and summary models are on disk, for views that show it,
    /// as recordings download them when they need them and Finder can remove them.
    func refreshModelDownloads() {
        speakerModelDownload.refresh()
        summaryModelDownload?.refresh()
    }

    /// Whether `summarizer` can summarize right now, and if not, why. Read this rather than
    /// `summarizer.availability` in views, so they update when the model finishes downloading.
    var summaryAvailability: SummarizerAvailability {
        _ = isSummaryModelDownloaded
        return summarizer.availability
    }

    /// Switches the model summaries and catch-ups are made with, from the next one; a summary
    /// under way finishes with the old model. Stops a download of the old model.
    func setSummaryModel(_ model: SummaryModel) {
        guard model != summaryModel else { return }
        summaryModelDownload?.cancel()
        settings.summaryModel = model
        summaryModel = model
        summarizer = model.makeSummarizer()
        summaryModelDownload = Self.makeDownload(for: summarizer)
        applyPreferences()
    }

    // MARK: Vocabulary

    /// How many `correctNotes(with:)` calls are running or waiting their turn.
    private var correctionsRunning = 0
    /// Whether `correctNotes(with:)` is running.
    var isCorrectingNotes: Bool { correctionsRunning > 0 }

    /// Applies `vocabulary` to every note in the notes folder, off the main thread, after any
    /// other change to notes asked for before. `nil` without a notes folder. The main window picks
    /// up the changed files as it watches the folder.
    func correctNotes(with vocabulary: Vocabulary) async throws -> NoteLibrary.VocabularyChanges? {
        guard let directory = notesFolder.directory else { return nil }
        correctionsRunning += 1
        defer { correctionsRunning -= 1 }
        return try await library.applyVocabulary(vocabulary, toNotesIn: directory)
    }

    // MARK: Notes

    /// Turns Chat on or off. Off, the main window leaves Chat, and Chat stops reading the notes.
    func setChatEnabled(_ enabled: Bool) {
        preferences.isChatEnabled = enabled
        guard !enabled else { return }
        leaveChat()
        noteChat.stop()
    }

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

    // MARK: Import

    /// Asks for an audio or video file, then shows the recorder while it's transcribed into a
    /// note. Ignored unless the coordinator `canImportAudio`.
    func importAudio() {
        guard coordinator.canImportAudio, let url = Self.chooseAudioFile() else { return }
        showRecorder()
        Task { [coordinator] in
            await coordinator.importAudio(from: url)
        }
    }

    private static func chooseAudioFile() -> URL? {
        let panel = NSOpenPanel()
        // Audio and video files; a video's sound is transcribed.
        panel.allowedContentTypes = [.audiovisualContent]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a recording to transcribe into a note. A video's sound works too."
        NSApp.activate()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
