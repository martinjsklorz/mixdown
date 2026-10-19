import MixdownCore
import SwiftUI

/// The Record section: one big button to start or stop, with one beside it to pause while
/// recording, the state Mixdown is in, and a summary of what it records with. The inputs
/// themselves are chosen in the Recording menu or Settings.
/// While recording with the live model, the text recognized so far replaces the summary.
struct RecorderView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(MainNavigation.self) private var navigation
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let coordinator = environment.coordinator

        Group {
            if coordinator.showsLiveTranscript {
                VStack(spacing: 24) {
                    hero(for: coordinator)
                        .frame(maxWidth: 420)
                    LiveTranscriptView(coordinator: coordinator)
                        .frame(maxWidth: 640, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    hero(for: coordinator)
                        .frame(maxWidth: 420)
                    Spacer(minLength: 24)
                    setup
                        .frame(maxWidth: 420)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Record")
    }

    // MARK: Hero

    /// The headline, the main control and a line of detail, depending on the phase.
    @ViewBuilder
    private func hero(for coordinator: RecordingCoordinator) -> some View {
        VStack(spacing: 20) {
            switch coordinator.phase {
            case .idle where environment.notesFolder.directory == nil:
                notesFolderPrompt

            case .idle where !coordinator.isModelDownloaded:
                headline(
                    "Download the Speech Model",
                    detail: "Recording starts once \(environment.model.displayName) is on this Mac."
                )
                downloadButton(for: coordinator)

            case .preparingModel(let progress):
                headline(
                    coordinator.isCancellingPreparation ? "Cancelling Download…" : "Downloading Model…",
                    detail: downloadDetail(for: coordinator)
                )
                ProgressView(value: progress) {
                    EmptyView()
                } currentValueLabel: {
                    Text(
                        ProgressText.detail(progress: progress, remaining: coordinator.timeRemaining)
                    )
                    .monospacedDigit()
                }
                .frame(maxWidth: 320)
                if coordinator.isPreparingModelForRecording {
                    summaryTemplatePicker(for: coordinator)
                } else {
                    Button("Cancel Download") { coordinator.cancelPreparation() }
                        .controlSize(.large)
                        .disabled(!coordinator.canCancelPreparation)
                }

            case .startingCapture:
                headline("Starting to Record…", detail: "Allow Mixdown to record if macOS asks.")
                RecordButton(isRecording: true) {
                    Task { await coordinator.stopRecording() }
                }
                .disabled(coordinator.isStopPending)
                caption(coordinator.isStopPending ? "Stopping…" : "Click to stop")

            case .recording(let startedAt):
                Text(startedAt, style: .timer)
                    .font(.system(size: 48, weight: .light).monospacedDigit())
                recordingControls(for: coordinator)
                caption("Recording · click to stop")
                InputLevelsView(coordinator: coordinator)
                summaryTemplatePicker(for: coordinator)

            case .paused(let recorded):
                Text(MenuBarLabel.elapsedText(Int(recorded)))
                    .font(.system(size: 48, weight: .light).monospacedDigit())
                    .foregroundStyle(.secondary)
                recordingControls(for: coordinator)
                caption("Paused · nothing is recorded until you resume")
                summaryTemplatePicker(for: coordinator)

            // The live model only finishes its last fraction of a second, too quick to track.
            case .transcribing where environment.model.isLive:
                headline("Finishing…", detail: "Your note appears in the sidebar in a moment.")
                ProgressView()
                    .controlSize(.large)

            case .transcribing(let progress):
                headline("Transcribing…", detail: "Your note appears in the sidebar when it's done.")
                ProgressView(value: progress) {
                    EmptyView()
                } currentValueLabel: {
                    Text(ProgressText.detail(progress: progress, remaining: coordinator.timeRemaining))
                        .monospacedDigit()
                }
                .frame(maxWidth: 320)
                summaryTemplatePicker(for: coordinator)

            case .summarizing:
                headline(
                    "Summarizing…",
                    detail: "\(environment.summarizer.info.displayName) is summarizing the transcript."
                )
                ProgressView()
                    .controlSize(.large)

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .multilineTextAlignment(.center)
                Button("Dismiss") { coordinator.dismissError() }
                // Recording still needs a notes folder, such as after the note couldn't be saved,
                // and the model, after a failed download.
                if environment.notesFolder.directory == nil {
                    notesFolderButtons
                } else if coordinator.isModelDownloaded {
                    startButton(for: coordinator)
                } else {
                    downloadButton(for: coordinator)
                }

            case .idle:
                headline("Ready to Record", detail: nil)
                startButton(for: coordinator)
            }
        }
        .multilineTextAlignment(.center)
        .animation(.default, value: coordinator.isRecording)
    }

    /// Stop in the middle, as when starting, with Pause or Resume beside it.
    private func recordingControls(for coordinator: RecordingCoordinator) -> some View {
        HStack(spacing: 20) {
            // Balances the pause button, so Stop stays where Record was.
            Color.clear
                .frame(width: PauseButton.size, height: PauseButton.size)
            RecordButton(isRecording: true) {
                Task { await coordinator.stopRecording() }
            }
            PauseButton(isPaused: coordinator.isPaused) {
                Task { await coordinator.togglePause() }
            }
        }
    }

    /// The template this recording's summary gets, preselected from Settings → Transcription and
    /// changeable until the summary is begun.
    @ViewBuilder
    private func summaryTemplatePicker(for coordinator: RecordingCoordinator) -> some View {
        if environment.summarizesNotes, let template = coordinator.recordingSummaryTemplate {
            Picker(
                "Summary:",
                selection: Binding(
                    get: { template },
                    set: { coordinator.chooseSummaryTemplate($0) }
                )
            ) {
                ForEach(SummaryTemplate.allCases) { template in
                    Text(template.displayName).tag(template)
                }
            }
            .fixedSize()
            .help("The summary template for this recording")
        }
    }

    private func downloadButton(for coordinator: RecordingCoordinator) -> some View {
        Button("Download Model", systemImage: "arrow.down.circle") {
            Task { await coordinator.prepareEngine() }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!coordinator.isIdle)
    }

    private func startButton(for coordinator: RecordingCoordinator) -> some View {
        VStack(spacing: 12) {
            RecordButton(isRecording: false) {
                Task { await coordinator.startRecording() }
            }
            .disabled(!coordinator.canStartRecording)
            caption(startCaption(for: coordinator))
        }
    }

    private func startCaption(for coordinator: RecordingCoordinator) -> String {
        if coordinator.selectedDevices.isEmpty {
            "Choose an input to record"
        } else if environment.notesFolder.directory == nil {
            "Choose a notes folder to record"
        } else {
            "Click to record · ⌘R"
        }
    }

    /// Asks for a notes folder on first run, or for another one when it can't be reached.
    @ViewBuilder
    private var notesFolderPrompt: some View {
        let notesFolder = environment.notesFolder
        headline(
            NotesFolderWarning.title(for: notesFolder.status) ?? "",
            detail: NotesFolderWarning.message(for: notesFolder.status, hasLegacyNotes: notesFolder.hasLegacyNotes)
        )
        notesFolderButtons
    }

    /// Choose Folder, or for a folder that can't be reached, Choose Another Folder and Try Again.
    private var notesFolderButtons: some View {
        let notesFolder = environment.notesFolder
        let isUnavailable = notesFolder.status != .notChosen
        return HStack {
            Button(isUnavailable ? "Choose Another Folder…" : "Choose Folder…", systemImage: "folder") {
                environment.chooseNotesFolder()
            }
            .buttonStyle(.borderedProminent)
            if isUnavailable {
                Button("Try Again") { notesFolder.refresh() }
            }
        }
        .controlSize(.large)
    }

    /// The model's name, and for a download a finished recording waits on, why it's downloading.
    private func downloadDetail(for coordinator: RecordingCoordinator) -> String {
        let name = environment.model.displayName
        guard coordinator.isPreparingModelForRecording else { return name }
        return "\(name) is no longer on this Mac. Transcribing starts once it's downloaded again."
    }

    private func headline(_ title: String, detail: String?) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.title2.weight(.semibold))
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: Setup

    /// What the next recording uses, with a way into Settings to change it.
    private var setup: some View {
        GroupBox {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                row("mic", "Microphone", microphoneName)
                row("speaker.wave.2", "System audio", environment.recordsSystemAudio ? "On" : "Off")
                row("waveform", "Model", TranscriptionSettingsView.label(for: environment.model))
                row("globe", "Language", languageName)
                row("sparkles", "Summary", summaryName)
                row("folder", "Notes folder", notesFolderName, help: environment.notesFolder.status.path)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("Setup")
                Spacer()
                Button("Change…") { navigation.showSettings(.recording, using: openSettings) }
                    .buttonStyle(.link)
                    .disabled(environment.coordinator.isRecording)
            }
        }
    }

    private func row(_ systemImage: String, _ label: String, _ value: String, help: String? = nil) -> some View {
        GridRow {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(help ?? value)
                .gridColumnAlignment(.leading)
        }
    }

    private var notesFolderName: String {
        let status = environment.notesFolder.status
        switch status {
        case .notChosen: return "Not chosen"
        case .available: return status.name ?? ""
        case .unavailable: return status.name.map { "\($0) (not available)" } ?? "Not available"
        }
    }

    private var microphoneName: String {
        guard let microphone = environment.selectedMicrophone else { return "Off" }
        return environment.followsDefaultMicrophone ? "System Default (\(microphone.name))" : microphone.name
    }

    private var summaryName: String {
        guard environment.summarizesNotes else { return "Off" }
        let name = environment.summarizer.info.displayName
        guard case .available = environment.summarizer.availability else { return "\(name) (not available)" }
        return name
    }

    /// Models that detect the language themselves ignore the setting.
    private var languageName: String {
        guard environment.model.supportsLanguageSelection, let code = environment.language else {
            return "Automatic"
        }
        return TranscriptionSettingsView.displayName(for: code)
    }
}

/// A round record button in the style of Voice Memos: a red dot that becomes a stop square.
private struct RecordButton: View {
    let isRecording: Bool
    let action: @MainActor () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.secondary.opacity(0.4), lineWidth: 4)
                RoundedRectangle(cornerRadius: isRecording ? 6 : 28)
                    .fill(.red)
                    .frame(width: isRecording ? 28 : 56, height: isRecording ? 28 : 56)
            }
            .frame(width: 72, height: 72)
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: isRecording)
        .accessibilityLabel(isRecording ? "Stop Recording" : "Start Recording")
        .help(isRecording ? "Stop Recording" : "Start Recording")
    }
}

/// A smaller round button beside Stop: a pause sign while recording, and a red dot to record
/// again while paused.
private struct PauseButton: View {
    static let size: CGFloat = 44

    let isPaused: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.secondary.opacity(0.4), lineWidth: 3)
                if isPaused {
                    Circle()
                        .fill(.red)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.size, height: Self.size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPaused ? "Resume Recording" : "Pause Recording")
        .help(isPaused ? "Resume Recording (⇧⌘P)" : "Pause Recording (⇧⌘P)")
    }
}
