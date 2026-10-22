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

/// Composition root: wires concrete implementations into the `RecordingCoordinator` and keeps
/// app preferences in sync with it.
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
    /// How much of `summaryModel` has downloaded, 0...1, while it downloads; `nil` otherwise.
    private(set) var summaryModelProgress: Double?
    /// Why `summaryModel` couldn't be downloaded or deleted, until the next try.
    private(set) var summaryModelError: String?
    /// Whether `summaryModel` is on disk; always true for Apple's, which macOS provides. Kept here
    /// so views update when a download finishes, which `summarizer.availability` alone wouldn't do.
    private(set) var isSummaryModelDownloaded: Bool
    private(set) var isDeletingSummaryModel = false
    /// Translates transcripts, into the coordinator's `translationLanguage` when there is one.
    let translator: any Translator
    /// The BCP 47 identifier of the language notes are translated into while `translatesNotes`;
    /// kept while that's off.
    private(set) var translationLanguage: String
    let notesFolder: NotesFolderStore
    let noteTrash: NoteTrash
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
    /// Whether the notes are in Spotlight. See `NoteSpotlight`.
    private(set) var indexesNotesInSpotlight: Bool
    /// Whether Chat is in the sidebar and the View menu. Off, it doesn't read the notes. See
    /// `NoteChat`.
    private(set) var isChatEnabled: Bool
    /// Whether the Dynamic Island is showing the recording time where it can always be seen, so
    /// the menu bar leaves it out. See `DynamicIsland.showsTimeAlone`.
    private(set) var dynamicIslandShowsTimeAlone = false
    /// The moment just marked while the user writes a note on it under the notch; `nil` once the
    /// field closes. See `markMoment()`.
    private(set) var momentDraft: MomentDraft?
    /// The catch-up asked for last, while it's summed up and shown under the notch; `nil` once
    /// its card closes. See `catchUp()`.
    private(set) var catchUpRequest: CatchUpRequest?
    /// How many of the last minutes of a recording `catchUp()` sums up.
    private(set) var catchUpMinutes: Int

    private let settings: AppSettings
    /// Shared by every coordinator, so the canceller it keeps loaded survives a model change.
    private static let echoCancellation = LocalVQEEchoCancellation()
    @ObservationIgnored private var deviceMonitor: Task<Void, Never>?
    @ObservationIgnored private var summaryModelDownload: Task<Void, Never>?
    @ObservationIgnored private var recordingClock: Task<Void, Never>?
    @ObservationIgnored private var recordingClockStart: Date?
    @ObservationIgnored private var callPrompt: CallPrompt?
    /// Created the first time it's shown.
    @ObservationIgnored private var dynamicIsland: DynamicIsland?
    /// The field for `momentDraft`. Created the first time it's shown.
    @ObservationIgnored private var momentEntry: MomentEntry?
    /// Closes the field for `momentDraft` if nothing is typed in time.
    @ObservationIgnored private var momentDraftTimeout: Task<Void, Never>?
    /// The card for `catchUpRequest`. Created the first time it's shown.
    @ObservationIgnored private var catchUpCard: CatchUpCard?
    /// Sums up `catchUpRequest`, then closes its card once it's had time to be read.
    @ObservationIgnored private var catchingUp: Task<Void, Never>?
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
        let model = settings.transcriptionModel
        // `SummaryModel.makeSummarizer()` is the ONE place the summarizer is chosen. To add a
        // backend, give it a case there; nothing else here changes.
        let summaryModel = settings.summaryModel
        let summarizer = summaryModel.makeSummarizer()
        // Likewise the ONE place the translator is chosen.
        let translator: any Translator = AppleTranslator()
        let noteTrash = NoteTrash()
        let noteReady = NoteReady(navigation: navigation)
        // Likewise the ONE place Chat's model and embeddings are chosen.
        self.noteChat = NoteChat(answerer: AppleIntelligenceAnswerer(), embedder: NaturalLanguageEmbedder())
        self.settings = settings
        self.model = model
        self.summaryModel = summaryModel
        self.summarizer = summarizer
        self.isSummaryModelDownloaded = (summarizer as? MLXSummarizer)?.isDownloaded ?? true
        self.translator = translator
        self.translationLanguage = settings.translationLanguage
        self.notesFolder = notesFolder
        self.noteTrash = noteTrash
        self.noteReady = noteReady
        self.notificationResponder = NotificationResponder(noteTrash: noteTrash, noteReady: noteReady)
        self.coordinator = Self.makeCoordinator(
            model: model,
            summarizer: settings.summarizesNotes ? summarizer : nil,
            translator: translator,
            notesDirectory: notesFolder.directory,
            settings: settings
        )
        self.showRecorder = { [weak navigation] in
            guard let navigation, let openWindow = navigation.openWindow else { return }
            navigation.show(.recorder, using: openWindow)
        }
        self.leaveChat = { [weak navigation] in
            if navigation?.destination == .chat { navigation?.destination = .notes }
        }
        self.notifiesAboutCalls = settings.notifiesAboutCalls
        self.recordsCallsAutomatically = settings.recordsCallsAutomatically
        self.isRecordingShortcutEnabled = settings.isRecordingShortcutEnabled
        self.showsRecordingInDynamicIsland = settings.showsRecordingInDynamicIsland
        self.islandLayout = settings.islandLayout
        self.indexesNotesInSpotlight = settings.indexesNotesInSpotlight
        self.isChatEnabled = settings.isChatEnabled
        self.catchUpMinutes = settings.catchUpMinutes

        startCoordinatorTasks()
        observeRecording()
        observeDynamicIsland()
        observeMoments()
        observeCatchUp()
        observePhaseForCues()
        observeNotesFolder()
        observeNewNotes()
        listenForRecordingShortcut()
        listenForMomentShortcut()
        listenForCatchUpShortcut()
        startCallPrompt()
    }

    // MARK: Composition

    private static func makeCoordinator(
        model: TranscriptionModel,
        summarizer: (any Summarizer)?,
        translator: any Translator,
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
            translator: translator,
            translationLanguage: settings.translatesNotes ? settings.translationLanguage : nil,
            options: TranscriptionOptions(language: settings.language),
            sourceLabels: settings.sourceLabels,
            preferredDeviceIDs: settings.selectedDeviceIDs,
            playbackMonitor: CoreAudioPlaybackMonitor(),
            echoCancellation: echoCancellation
        )
        coordinator.cancelsEcho = settings.cancelsEcho
        coordinator.translatesLiveText = settings.translatesLiveText
        coordinator.vocabulary = settings.vocabulary
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
            var layout = islandLayout
            // Only a live model has words to show while recording.
            layout.showsLiveText = layout.showsLiveText && coordinator.showsLiveTranscript
            return (coordinator.isRecording && showsRecordingInDynamicIsland, layout)
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

    /// Takes the Mark Moment shortcut only while recording, so other apps get those keys
    /// otherwise, and shows the field for `momentDraft` while there is one. A recording that
    /// stops closes the field, dropping a moment not yet added with Return.
    private func observeMoments() {
        let (isRecording, draft) = withObservationTracking {
            (coordinator.isRecording, momentDraft)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMoments() }
        }
        if isRecording {
            KeyboardShortcuts.enable(.markMoment)
        } else {
            KeyboardShortcuts.disable(.markMoment)
            closeMomentDraft()
        }
        if let draft, isRecording {
            let entry =
                momentEntry
                ?? MomentEntry(environment: self, islandFrame: { [weak self] in self?.dynamicIsland?.frame })
            momentEntry = entry
            entry.show(draft)
        } else {
            momentEntry?.hide()
        }
    }

    /// Takes the Catch Me Up shortcut only while recording, so other apps get those keys
    /// otherwise, and shows the card for `catchUpRequest` while there is one. A recording that
    /// stops closes the card.
    private func observeCatchUp() {
        let (isRecording, request) = withObservationTracking {
            (coordinator.isRecording, catchUpRequest)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeCatchUp() }
        }
        if isRecording {
            KeyboardShortcuts.enable(.catchUp)
        } else {
            KeyboardShortcuts.disable(.catchUp)
            closeCatchUp()
        }
        if let request, isRecording {
            let card =
                catchUpCard
                ?? CatchUpCard(environment: self, islandFrame: { [weak self] in self?.dynamicIsland?.frame })
            catchUpCard = card
            card.show(request)
        } else {
            catchUpCard?.hide()
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

    /// Points the coordinator and Spotlight at the notes folder whenever it's chosen, goes away or
    /// comes back. Without one, recording is disabled.
    private func observeNotesFolder() {
        let directory = withObservationTracking {
            notesFolder.directory
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeNotesFolder() }
        }
        coordinator.noteWriter = directory.map { MarkdownNoteWriter(directory: $0) }
        noteSpotlight.update(directory: directory, isEnabled: indexesNotesInSpotlight)
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
    /// transcribing, translating or summarizing, it beeps, as recording can start once that's done.
    /// When recording can't start for something the user has to do (no notes folder, model or
    /// input), it opens Record instead, which says what.
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

    // MARK: Moments

    /// How long the field for a new moment waits for typing before it closes.
    private static let momentDraftTimeoutDuration = Duration.seconds(5)

    /// Starts on the Mark Moment shortcut, from any app. `observeMoments()` takes it only while
    /// recording.
    private func listenForMomentShortcut() {
        KeyboardShortcuts.onKeyUp(for: .markMoment) { [weak self] in
            self?.markMoment()
        }
        KeyboardShortcuts.disable(.markMoment)
    }

    /// Marks the point the recording has reached, and opens a field under the notch to write a
    /// few words about it. Return adds the moment to the note; Escape, clicking elsewhere, or
    /// `momentDraftTimeoutDuration` without typing drops it. Beeps when not recording.
    func markMoment() {
        guard let time = coordinator.momentTime else {
            NSSound.beep()
            return
        }
        // Both would go under the notch.
        closeCatchUp()
        let draft = MomentDraft(time: time)
        momentDraft = draft
        momentDraftTimeout?.cancel()
        momentDraftTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.momentDraftTimeoutDuration)
            guard let self, !Task.isCancelled, self.momentDraft === draft, draft.text.isEmpty else { return }
            self.closeMomentDraft()
        }
    }

    /// Adds `momentDraft` to the note, with what was typed, and closes its field.
    func addMomentDraft() {
        guard let momentDraft else { return }
        coordinator.addMoment(at: momentDraft.time, text: momentDraft.text)
        closeMomentDraft()
    }

    /// Closes the field for `momentDraft`, dropping the moment unless it was added.
    func closeMomentDraft() {
        guard momentDraft != nil else { return }
        momentDraft = nil
        momentDraftTimeout?.cancel()
        momentDraftTimeout = nil
    }

    // MARK: Catch Me Up

    /// How long a catch-up stays up once it's in: long enough to read, at about three words a
    /// second, and at least 15 seconds. A failure, which only says why, goes sooner.
    private static func catchUpReadingTime(for state: CatchUpRequest.State) -> Duration {
        switch state {
        case .summarizing:
            return .zero
        case .ready(let catchUp):
            let words = catchUp.points.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
            return max(.seconds(15), .seconds(5) + .milliseconds(words * 350))
        case .failed:
            return .seconds(8)
        }
    }

    /// Starts on the Catch Me Up shortcut, from any app. `observeCatchUp()` takes it only while
    /// recording.
    private func listenForCatchUpShortcut() {
        KeyboardShortcuts.onKeyUp(for: .catchUp) { [weak self] in
            self?.catchUp()
        }
        KeyboardShortcuts.disable(.catchUp)
    }

    /// Has Apple Intelligence sum up the last `catchUpMinutes` of the live text, on this Mac, in a
    /// card under the notch, for when the user drifted off. If the card is open already, closes
    /// it instead. It closes by itself once it's had time to be read, unless the pointer is over
    /// it. Beeps when not recording.
    func catchUp() {
        guard catchUpRequest == nil else {
            closeCatchUp()
            return
        }
        guard coordinator.isRecording else {
            NSSound.beep()
            return
        }
        // Both would go under the notch.
        closeMomentDraft()
        let request = CatchUpRequest(minutes: catchUpMinutes)
        catchUpRequest = request
        catchingUp = Task { [weak self, coordinator, summarizer] in
            do {
                let catchUp = try await coordinator.catchUp(
                    onLast: TimeInterval(request.minutes * 60),
                    with: summarizer
                )
                request.state = .ready(catchUp)
                Self.announce(catchUp.points.joined(separator: " "))
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                let message: String
                if case SummarizationError.unavailable(let reason) = error {
                    // What to turn on, without "Summaries aren't available".
                    message = reason
                } else {
                    message = error.localizedDescription
                }
                request.state = .failed(message)
                Self.announce(message)
            }
            try? await Task.sleep(for: Self.catchUpReadingTime(for: request.state))
            // Not while it's being read.
            while !Task.isCancelled, request.isHovered {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, let self, self.catchUpRequest === request else { return }
            self.closeCatchUp()
        }
    }

    /// Closes the card for `catchUpRequest`, stopping the catch-up if it's still being summed up.
    func closeCatchUp() {
        guard catchUpRequest != nil else { return }
        catchUpRequest = nil
        catchingUp?.cancel()
        catchingUp = nil
    }

    /// Reads `text` out with VoiceOver, as the card never has the focus.
    private static func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    func setCatchUpMinutes(_ minutes: Int) {
        settings.catchUpMinutes = minutes
        catchUpMinutes = settings.catchUpMinutes
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
            translator: translator,
            notesDirectory: notesFolder.directory,
            pendingNotes: coordinator.takePendingNotes(),
            settings: settings
        )
        startCoordinatorTasks()
    }

    // MARK: Summary

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
        cancelSummaryModelDownload()
        settings.summaryModel = model
        summaryModel = model
        summarizer = model.makeSummarizer()
        summaryModelError = nil
        isSummaryModelDownloaded = (summarizer as? MLXSummarizer)?.isDownloaded ?? true
        if coordinator.summarizer != nil { coordinator.summarizer = summarizer }
    }

    /// Downloads `summaryModel` if Mixdown downloads it, showing progress in
    /// `summaryModelProgress`. Keeps going while Settings is closed.
    func downloadSummaryModel() {
        guard summaryModelDownload == nil, let summarizer = summarizer as? MLXSummarizer else { return }
        summaryModelError = nil
        summaryModelProgress = 0
        let reportProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            guard let self else { return }
            Task { @MainActor in self.reportSummaryModelProgress(fraction, of: summarizer) }
        }
        summaryModelDownload = Task { [weak self] in
            var failure: String?
            do {
                try await summarizer.download(progress: reportProgress)
            } catch {
                failure = "Couldn't download \(summarizer.model.displayName): \(error.localizedDescription)"
            }
            // Cancelled: `cancelSummaryModelDownload()` reset the state, and another download, or
            // model, may have taken over since.
            guard !Task.isCancelled, let self else { return }
            self.summaryModelDownload = nil
            self.summaryModelProgress = nil
            self.summaryModelError = failure
            self.isSummaryModelDownloaded = summarizer.isDownloaded
        }
    }

    private func reportSummaryModelProgress(_ fraction: Double, of summarizer: MLXSummarizer) {
        guard self.summarizer as? MLXSummarizer === summarizer, let progress = summaryModelProgress else { return }
        // Hops to the main actor can arrive out of order.
        summaryModelProgress = max(progress, fraction)
    }

    /// Stops downloading `summaryModel`. What's on disk is kept, so a new download resumes.
    func cancelSummaryModelDownload() {
        summaryModelDownload?.cancel()
        summaryModelDownload = nil
        summaryModelProgress = nil
    }

    /// Removes `summaryModel`'s files, if Mixdown downloaded them.
    func deleteSummaryModel() async {
        guard let summarizer = summarizer as? MLXSummarizer else { return }
        isDeletingSummaryModel = true
        defer { isDeletingSummaryModel = false }
        do {
            try await summarizer.deleteModel()
        } catch {
            summaryModelError = "Couldn't delete \(summarizer.model.displayName): \(error.localizedDescription)"
        }
        guard self.summarizer as? MLXSummarizer === summarizer else { return }
        isSummaryModelDownloaded = summarizer.isDownloaded
    }

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

    // MARK: Translation

    /// Whether notes are translated into `translationLanguage`. Takes effect from the next note.
    var translatesNotes: Bool {
        get { coordinator.translationLanguage != nil }
        set {
            settings.translatesNotes = newValue
            coordinator.translationLanguage = newValue ? translationLanguage : nil
        }
    }

    /// Picks the language notes are translated into. Takes effect from the next note.
    func setTranslationLanguage(_ language: String) {
        settings.translationLanguage = language
        translationLanguage = language
        if translatesNotes { coordinator.translationLanguage = language }
    }

    /// Whether the live text is translated into `translationLanguage` while recording, too. Takes
    /// effect from the next recording.
    var translatesLiveText: Bool {
        get { coordinator.translatesLiveText }
        set {
            settings.translatesLiveText = newValue
            coordinator.translatesLiveText = newValue
        }
    }

    // MARK: Vocabulary

    /// Words to correct in transcripts. Takes effect from the next transcription; notes already
    /// written change only with `correctNotes(with:)`.
    var vocabulary: Vocabulary {
        get { coordinator.vocabulary }
        set {
            settings.vocabulary = newValue
            coordinator.vocabulary = newValue
        }
    }

    /// Whether `correctNotes(with:)` is running.
    private(set) var isCorrectingNotes = false

    /// Applies `vocabulary` to every note in the notes folder, off the main thread. `nil` without
    /// a notes folder. The main window picks up the changed files as it watches the folder.
    func correctNotes(with vocabulary: Vocabulary) async throws -> NoteLibrary.VocabularyChanges? {
        guard let directory = notesFolder.directory else { return nil }
        isCorrectingNotes = true
        defer { isCorrectingNotes = false }
        return try await Task.detached(priority: .userInitiated) {
            try NoteLibrary.applyVocabulary(vocabulary, toNotesIn: directory)
        }.value
    }

    // MARK: Notes

    func setIndexesNotesInSpotlight(_ enabled: Bool) {
        settings.indexesNotesInSpotlight = enabled
        indexesNotesInSpotlight = enabled
        noteSpotlight.update(directory: notesFolder.directory, isEnabled: enabled)
    }

    func setChatEnabled(_ enabled: Bool) {
        settings.isChatEnabled = enabled
        isChatEnabled = enabled
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
}
