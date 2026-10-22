import KeyboardShortcuts
import MixdownCore
import SwiftUI

/// The Record section: one big button to start or stop, with ones beside it to mark a moment and
/// to pause while recording, the state Mixdown is in, and a summary of what it records with. The inputs
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
                progressBar(progress, for: coordinator)
                if coordinator.isPreparingModelForRecording {
                    summaryTemplatePicker(for: coordinator)
                } else {
                    Button("Cancel Download") { coordinator.cancelPreparation() }
                        .controlSize(.large)
                        .disabled(!coordinator.canCancelPreparation)
                }

            case .startingCapture:
                headline("Starting to Record…", detail: "Allow Mixdown to record if macOS asks.")
                stopButton(for: coordinator)
                    .disabled(coordinator.isStopPending)
                caption(coordinator.isStopPending ? "Stopping…" : "Click to stop")

            case .recording(let startedAt):
                Text(startedAt, style: .timer)
                    .font(.system(size: 48, weight: .light).monospacedDigit())
                recordingControls(for: coordinator)
                caption("Recording · click to stop")
                InputLevelsView(coordinator: coordinator)
                if coordinator.isAskingIfStillRecording {
                    stillRecordingQuestion(for: coordinator)
                }
                summaryTemplatePicker(for: coordinator)

            case .paused(let recorded):
                Text(ProgressText.elapsed(Int(recorded)))
                    .font(.system(size: 48, weight: .light).monospacedDigit())
                    .foregroundStyle(.secondary)
                recordingControls(for: coordinator)
                caption("Paused · nothing is recorded until you resume")
                summaryTemplatePicker(for: coordinator)

            // The live model only finishes its last fraction of a second, too quick to track. An
            // imported file it transcribes whole.
            case .transcribing where environment.model.isLive && coordinator.importingFileName == nil:
                headline("Finishing…", detail: "Your note appears in the sidebar in a moment.")
                ProgressView()
                    .controlSize(.large)

            case .transcribing(let progress):
                headline(
                    coordinator.importingFileName.map { "Transcribing “\($0)”…" } ?? "Transcribing…",
                    detail: "Your note appears in the sidebar when it's done."
                )
                progressBar(progress, for: coordinator)
                summaryTemplatePicker(for: coordinator)
                cancelImportButton(for: coordinator)

            case .translating:
                headline(
                    "Translating…",
                    detail: "\(environment.translator.info.displayName) is translating the transcript into "
                        + "\(TranslationSettingsView.name(of: environment.translationLanguage))."
                )
                ProgressView()
                    .controlSize(.large)
                summaryTemplatePicker(for: coordinator)
                cancelImportButton(for: coordinator)

            case .summarizing:
                headline(
                    "Summarizing…",
                    detail: "\(environment.summarizer.info.displayName) is summarizing the transcript."
                )
                ProgressView()
                    .controlSize(.large)
                cancelImportButton(for: coordinator)

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
        .animation(.default, value: coordinator.isAskingIfStillRecording)
    }

    /// Asks whether the recording was left running, after a while without speech. Speaking
    /// answers it too.
    private func stillRecordingQuestion(for coordinator: RecordingCoordinator) -> some View {
        VStack(spacing: 8) {
            Label(
                "Still recording? \(StillRecordingPrompt.message(for: coordinator.stillRecordingDelay))",
                systemImage: "waveform.slash"
            )
            .foregroundStyle(.orange)
            .font(.callout)
            HStack {
                Button("Stop Recording") {
                    Task { await coordinator.stopRecording() }
                }
                Button("Keep Recording") { coordinator.keepRecording() }
            }
            .controlSize(.small)
        }
        .transition(.opacity)
    }

    /// Stop in the middle, as when starting, with Mark Moment on one side and Pause or Resume on
    /// the other.
    private func recordingControls(for coordinator: RecordingCoordinator) -> some View {
        HStack(spacing: 20) {
            MomentButton(momentCount: coordinator.moments.count) { environment.markMoment() }
            stopButton(for: coordinator)
            PauseButton(isPaused: coordinator.isPaused) {
                Task { await coordinator.togglePause() }
            }
        }
    }

    private func stopButton(for coordinator: RecordingCoordinator) -> some View {
        RecordButton(isRecording: true) {
            Task { await coordinator.stopRecording() }
        }
    }

    /// Stops an import without saving a note. A recording has no such button, as its audio
    /// isn't kept anywhere else.
    @ViewBuilder
    private func cancelImportButton(for coordinator: RecordingCoordinator) -> some View {
        if coordinator.importingFileName != nil {
            Button("Cancel Import") { coordinator.cancelImport() }
                .controlSize(.large)
        }
    }

    /// A download's or transcription's progress, with the time left.
    private func progressBar(_ progress: Double, for coordinator: RecordingCoordinator) -> some View {
        ProgressView(value: progress) {
            EmptyView()
        } currentValueLabel: {
            Text(ProgressText.detail(progress: progress, remaining: coordinator.timeRemaining))
                .monospacedDigit()
        }
        .frame(maxWidth: 320)
    }

    /// The template this recording's summary gets, preselected from Settings → Summary and
    /// changeable until the summary is begun.
    @ViewBuilder
    private func summaryTemplatePicker(for coordinator: RecordingCoordinator) -> some View {
        if environment.summarizesNotes, let template = coordinator.recordingSummaryTemplate {
            // Still offered if it was deleted while recording, so the picker isn't blank.
            let templates =
                environment.summaryTemplates.contains { $0.id == template.id }
                ? environment.summaryTemplates : environment.summaryTemplates + [template]
            Picker(
                "Summary:",
                selection: Binding(
                    get: { template.id },
                    set: { id in templates.first { $0.id == id }.map(coordinator.chooseSummaryTemplate) }
                )
            ) {
                ForEach(templates) { template in
                    Text(template.displayName).tag(template.id)
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

    /// Only shown with a notes folder; without one, `hero(for:)` asks for it instead.
    private func startCaption(for coordinator: RecordingCoordinator) -> String {
        coordinator.selectedDevices.isEmpty ? "Choose an input to record" : "Click to record · ⌘R"
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
                row("waveform", "Model", environment.model.menuLabel)
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
        guard case .available = environment.summaryAvailability else { return "\(name) (not available)" }
        return name
    }

    /// Models that detect the language themselves ignore the setting.
    private var languageName: String {
        guard environment.model.supportsLanguageSelection, let code = environment.language else {
            return "Automatic"
        }
        return LanguagePicker.displayName(for: code)
    }
}
