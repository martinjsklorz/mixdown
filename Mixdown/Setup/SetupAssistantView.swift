import AppKit
import KeyboardShortcuts
import MixdownAudio
import MixdownCore
import SwiftUI
import UserNotifications

/// Walks through setting Mixdown up, a page at a time: the notes folder and the speech model that
/// recording needs, the inputs and their permissions, then calls, notifications and shortcuts.
///
/// Shown over the main window at first launch, until it's finished or put off with **Set Up
/// Later**; Help › Setup Assistant… opens it again. Everything it sets is in Settings too, and
/// Record still asks for whatever is missing.
struct SetupAssistantView: View {
    enum Step: Int, CaseIterable {
        case welcome
        case notesFolder
        case model
        case inputs
        case calls
        case shortcuts
        case done
    }

    @Environment(AppEnvironment.self) private var environment
    @Environment(MainNavigation.self) private var navigation
    @State private var step = Step.welcome

    var body: some View {
        VStack(spacing: 0) {
            page
                .id(step)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            pageDots
                .padding(.vertical, 12)
            Divider()
            footer
        }
        .frame(width: 580, height: 580)
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome: WelcomePage()
        case .notesFolder: NotesFolderPage()
        case .model: ModelPage()
        case .inputs: InputsPage()
        case .calls: CallsPage()
        case .shortcuts: ShortcutsPage()
        case .done: DonePage()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step != .done {
                Button("Set Up Later", action: finish)
                    .keyboardShortcut(.cancelAction)
                    .help("Close the assistant. Open it again from Help › Setup Assistant….")
            }
            Spacer()
            if step != .welcome {
                Button("Back") { go(to: step.rawValue - 1) }
            }
            Button(continueTitle, action: next)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
        }
        .controlSize(.large)
        .padding(16)
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(Step.allCases, id: \.self) { page in
                Circle()
                    .fill(page == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    // MARK: Moving on

    private var continueTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .model where startsDownload: "Download and Continue"
        case .done: "Start Using Mixdown"
        default: "Continue"
        }
    }

    /// Recording needs a notes folder; the rest can be done later.
    private var canContinue: Bool {
        step != .notesFolder || environment.notesFolder.directory != nil
    }

    /// Whether continuing from the model page starts downloading it, which then carries on in the
    /// background.
    private var startsDownload: Bool {
        !environment.coordinator.isModelDownloaded && environment.coordinator.isIdle
    }

    private func next() {
        if step == .model, startsDownload {
            let coordinator = environment.coordinator
            Task { await coordinator.prepareEngine() }
        }
        if step == .done {
            finish()
        } else {
            go(to: step.rawValue + 1)
        }
    }

    private func go(to rawValue: Int) {
        guard let step = Step(rawValue: rawValue) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { self.step = step }
    }

    /// Closes the assistant for good, leaving Record to show what's still missing.
    private func finish() {
        let settings = AppSettings()
        settings.needsSetup = false
        navigation.destination = .recorder
        navigation.isShowingSetup = false
    }
}

// MARK: - Page layout

/// A page of the assistant: a symbol, a title and what the page is about, then its controls.
private struct SetupPage<Content: View>: View {
    let title: String
    let systemImage: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 40))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(height: 48)
                Text(title)
                    .font(.title.weight(.semibold))
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 48)
            .padding(.top, 28)
            .padding(.bottom, 8)

            content
        }
    }
}

/// A row saying something is done, such as a permission being granted.
private struct DoneLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Label(title, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
    }
}

/// A caption under a control, red for problems.
private func caption(_ text: String, isWarning: Bool = false) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(isWarning ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
}

// MARK: - Welcome

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.top, 36)
            Text("Welcome to Mixdown")
                .font(.largeTitle.weight(.semibold))
                .padding(.top, 12)
            Text("A few steps, and you're ready to record.")
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 18) {
                feature(
                    "waveform.and.mic",
                    "Record anything",
                    "Your microphone, whatever your Mac plays, such as a call, or both at once."
                )
                feature(
                    "doc.text",
                    "Get a Markdown note",
                    "A transcript with a summary on top, saved in a folder you choose."
                )
                feature(
                    "lock.shield",
                    "Stay on your Mac",
                    "Transcribing and summarizing happen here. Your audio never leaves this Mac."
                )
            }
            .padding(.horizontal, 64)
            .padding(.top, 32)
        }
    }

    private func feature(_ systemImage: String, _ title: String, _ detail: String) -> some View {
        GridRow {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Notes folder

private struct NotesFolderPage: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let notesFolder = environment.notesFolder

        SetupPage(
            title: "Choose a Notes Folder",
            systemImage: "folder",
            detail: "Mixdown saves each recording as a Markdown file, which any editor and Obsidian "
                + "can open. Pick a folder of its own, such as Documents › Mixdown, or one in your vault."
        ) {
            Form {
                Section {
                    LabeledContent("Folder") {
                        HStack {
                            Text(notesFolder.status.path ?? "Not chosen")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(notesFolder.directory == nil ? Color.secondary : Color.primary)
                                .help(notesFolder.status.path ?? "")
                            if notesFolder.directory != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityLabel("Chosen")
                            }
                        }
                    }
                    if case .unavailable = notesFolder.status,
                        let warning = NotesFolderWarning.message(
                            for: notesFolder.status,
                            hasLegacyNotes: notesFolder.hasLegacyNotes
                        )
                    {
                        caption(warning, isWarning: true)
                    }
                    HStack {
                        Spacer()
                        Button(
                            notesFolder.directory == nil ? "Choose Folder…" : "Choose Another Folder…",
                            systemImage: "folder"
                        ) {
                            environment.chooseNotesFolder()
                        }
                    }
                } footer: {
                    caption(
                        "Use New Folder in the dialog to make one just for your notes. You can change "
                            + "it later under Settings → General."
                            + (notesFolder.hasLegacyNotes
                                ? " The notes you've already recorded move there too." : "")
                    )
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - Speech model

private struct ModelPage: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let coordinator = environment.coordinator

        SetupPage(
            title: "Pick a Speech Model",
            systemImage: "waveform",
            detail: "The model turns speech into text on this Mac. It's downloaded once, from Hugging "
                + "Face or, for Apple Speech, from Apple; your recordings are never uploaded."
        ) {
            Form {
                Section {
                    Picker(
                        "Model",
                        selection: Binding(
                            get: { environment.model },
                            set: { environment.setModel($0) }
                        )
                    ) {
                        ForEach(TranscriptionModel.available) { model in
                            Text(TranscriptionSettingsView.label(for: model)).tag(model)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .disabled(!environment.canChangeModel)

                    Picker(
                        "Language",
                        selection: Binding(
                            get: { environment.language },
                            set: { environment.setLanguage($0) }
                        )
                    ) {
                        Text("Automatic").tag(String?.none)
                        Divider()
                        ForEach(TranscriptionSettingsView.languages, id: \.self) { code in
                            Text(TranscriptionSettingsView.displayName(for: code)).tag(Optional(code))
                        }
                    }
                    .disabled(!environment.model.supportsLanguageSelection)
                } footer: {
                    caption(
                        environment.model.labelsSpeakers
                            ? "This model labels speakers and detects the language itself."
                            : environment.model.isManagedBySystem
                                ? "Apple's model is part of macOS. Automatic uses your Mac's language."
                                : "Larger models are more accurate but slower. Change it later under "
                                    + "Settings → Transcription."
                    )
                }

                Section {
                    status(for: coordinator)
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func status(for coordinator: RecordingCoordinator) -> some View {
        if case .preparingModel(let progress) = coordinator.phase {
            HStack(alignment: .bottom, spacing: 12) {
                ProgressView(value: progress) {
                    Text("Downloading \(environment.model.displayName)…")
                } currentValueLabel: {
                    Text(ProgressText.detail(progress: progress, remaining: coordinator.timeRemaining))
                        .monospacedDigit()
                }
                Button("Cancel") { coordinator.cancelPreparation() }
                    .disabled(coordinator.isPreparingModelForRecording)
            }
            caption("You can go on while it downloads. The menu bar shows the time left.")
        } else if coordinator.isModelDownloaded {
            DoneLabel("Downloaded and ready")
        } else {
            LabeledContent("Not downloaded yet") {
                Button("Download", systemImage: "arrow.down.circle") {
                    Task { await coordinator.prepareEngine() }
                }
                .disabled(!coordinator.isIdle)
            }
        }
        if let modelError = coordinator.modelError {
            caption(modelError, isWarning: true)
        }
    }
}

// MARK: - Inputs

private struct InputsPage: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var microphoneAccess = AudioPermissions.microphoneStatus()

    var body: some View {
        let hasSystemAudio = environment.coordinator.devices.contains { $0.kind == .systemAudio }

        SetupPage(
            title: "What to Record",
            systemImage: "mic",
            detail: "Record your microphone for voice notes and meetings in the room. Add system audio "
                + "to hear the other people on a call too."
        ) {
            Form {
                Section {
                    MicrophonePicker()
                    if hasSystemAudio {
                        Toggle(
                            "Record system audio",
                            isOn: Binding(
                                get: { environment.recordsSystemAudio },
                                set: { environment.setRecordsSystemAudio($0) }
                            )
                        )
                    }
                } footer: {
                    caption(
                        "System Default follows the Mac's input, so connecting AirPods switches to them. "
                            + "Change inputs any time in the Recording menu."
                    )
                }

                Section("Permissions") {
                    LabeledContent("Microphone") {
                        microphoneAccessControl
                    }
                    if microphoneAccess == .denied {
                        caption(
                            "Turned off for Mixdown. Turn it on in System Settings › Privacy & Security "
                                + "› Microphone.",
                            isWarning: true
                        )
                    }
                    LabeledContent("System audio") {
                        Text("Asked the first time")
                            .foregroundStyle(.secondary)
                    }
                    caption(
                        "macOS asks the first time you record system audio. Choose Allow, or Mixdown "
                            + "records silence."
                    )
                }
            }
            .formStyle(.grouped)
        }
        // The user can change it in System Settings, so re-read on coming back from there.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            microphoneAccess = AudioPermissions.microphoneStatus()
        }
    }

    @ViewBuilder
    private var microphoneAccessControl: some View {
        switch microphoneAccess {
        case .granted:
            DoneLabel("Allowed")
        case .notDetermined:
            Button("Allow…") {
                Task {
                    _ = await AudioPermissions.requestMicrophoneAccess()
                    microphoneAccess = AudioPermissions.microphoneStatus()
                }
            }
        case .denied:
            Button("Open System Settings") { Self.openMicrophonePrivacySettings() }
        }
    }

    /// Opens Privacy & Security › Microphone.
    private static func openMicrophonePrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Calls and notifications

private struct CallsPage: View {
    @Environment(AppEnvironment.self) private var environment
    @AppStorage(AppSettings.Key.showsNotifications) private var showsNotifications = true
    @State private var notificationAccess: UNAuthorizationStatus?

    var body: some View {
        SetupPage(
            title: "Calls and Notifications",
            systemImage: "phone.bubble",
            detail: "Mixdown notices when Zoom, Teams, FaceTime or a browser starts using the "
                + "microphone, and can offer to record the call."
        ) {
            Form {
                Section {
                    Toggle(
                        "Notify when calls start and end",
                        isOn: Binding(
                            get: { environment.notifiesAboutCalls },
                            set: { environment.setNotifiesAboutCalls($0) }
                        )
                    )
                    Toggle(
                        "Record calls automatically",
                        isOn: Binding(
                            get: { environment.recordsCallsAutomatically },
                            set: { environment.setRecordsCallsAutomatically($0) }
                        )
                    )
                } footer: {
                    caption(
                        "Without automatic recording, a notification asks whether to record. Recording "
                            + "a call turns on system audio."
                    )
                }

                Section {
                    Toggle("Show notifications", isOn: $showsNotifications)
                    if showsNotifications {
                        LabeledContent("Permission") {
                            notificationAccessControl
                        }
                    }
                } footer: {
                    caption(
                        "Notifications ask about calls, say when a note is ready, and offer Restore after "
                            + "deleting a note."
                    )
                }
            }
            .formStyle(.grouped)
        }
        .task { await refresh() }
        // The user can change it in System Settings, so re-read on coming back from there.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await refresh() }
        }
    }

    @ViewBuilder
    private var notificationAccessControl: some View {
        switch notificationAccess {
        case .notDetermined:
            Button("Allow…") {
                Task {
                    await Notifications.requestAuthorization()
                    await refresh()
                }
            }
        case .denied:
            HStack {
                Text("Turned off")
                    .foregroundStyle(.red)
                Button("Open System Settings") { Notifications.openSystemSettings() }
            }
        case nil:
            EmptyView()
        default:
            DoneLabel("Allowed")
        }
    }

    private func refresh() async {
        notificationAccess = await Notifications.authorizationStatus()
    }
}

// MARK: - Shortcuts and startup

private struct ShortcutsPage: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var launchAtLogin = LaunchAtLogin()

    var body: some View {
        SetupPage(
            title: "Always at Hand",
            systemImage: "keyboard",
            detail: "Mixdown lives in the menu bar. Start and stop recording from any app with a "
                + "shortcut, without switching to Mixdown."
        ) {
            Form {
                Section {
                    Toggle(
                        "Start and stop recording from any app",
                        isOn: Binding(
                            get: { environment.isRecordingShortcutEnabled },
                            set: { environment.setRecordingShortcutEnabled($0) }
                        )
                    )
                    // Hidden rather than disabled: the recorder is an AppKit field that ignores
                    // SwiftUI's `disabled`.
                    if environment.isRecordingShortcutEnabled {
                        KeyboardShortcuts.Recorder("Shortcut", name: .toggleRecording)
                    }
                } footer: {
                    caption("Click the shortcut and press new keys to change it.")
                }

                Section {
                    Toggle(
                        "Launch Mixdown at login",
                        isOn: Binding(
                            get: { launchAtLogin.isEnabled },
                            set: { launchAtLogin.setEnabled($0) }
                        )
                    )
                    if launchAtLogin.requiresApproval {
                        caption("Allow Mixdown in System Settings › General › Login Items.")
                    }
                    if let error = launchAtLogin.errorMessage {
                        caption(error, isWarning: true)
                    }
                } footer: {
                    caption("Keeps Mixdown in the menu bar, ready for calls, after you restart your Mac.")
                }
            }
            .formStyle(.grouped)
        }
        // The user can change it in System Settings › General › Login Items.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            launchAtLogin.refresh()
        }
    }
}

// MARK: - Done

private struct DonePage: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(MainNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let coordinator = environment.coordinator

        SetupPage(
            title: "You're All Set",
            systemImage: "checkmark.seal",
            detail: startHint
        ) {
            Form {
                Section {
                    row("Notes folder", systemImage: "folder", isReady: environment.notesFolder.directory != nil) {
                        Text(environment.notesFolder.status.name ?? "Not chosen")
                    }
                    row("Speech model", systemImage: "waveform", isReady: coordinator.isModelDownloaded) {
                        if case .preparingModel(let progress) = coordinator.phase {
                            Text("Downloading, \(progress.formatted(.percent.precision(.fractionLength(0))))")
                                .monospacedDigit()
                        } else {
                            Text(coordinator.isModelDownloaded ? environment.model.displayName : "Not downloaded")
                        }
                    }
                    row("Inputs", systemImage: "mic", isReady: !coordinator.selectedDevices.isEmpty) {
                        Text(inputsName)
                    }
                } footer: {
                    HStack {
                        caption("Everything here is in Settings too.")
                        Spacer()
                        Button("Mixdown Help") { navigation.showHelp(using: openWindow) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func row<Value: View>(
        _ title: String,
        systemImage: String,
        isReady: Bool,
        @ViewBuilder value: () -> Value
    ) -> some View {
        LabeledContent {
            HStack {
                value()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(isReady ? Color.green : Color.orange)
                    .accessibilityLabel(isReady ? "Ready" : "Not ready")
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    /// How to start recording, with the global shortcut if it's on.
    private var startHint: String {
        let inApp = "Click the red button in Record, or press ⌘R, to start recording."
        guard environment.isRecordingShortcutEnabled,
            let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        else { return inApp }
        return inApp + " From any other app, press \(shortcut.description)."
    }

    private var inputsName: String {
        var names: [String] = []
        if let microphone = environment.selectedMicrophone { names.append(microphone.name) }
        if environment.recordsSystemAudio { names.append("System Audio") }
        return names.isEmpty ? "None" : names.joined(separator: " + ")
    }
}
