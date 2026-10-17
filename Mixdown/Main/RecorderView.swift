import MixdownCore
import SwiftUI

/// The Record section: one big button to start or stop, the state Mixdown is in, and a summary
/// of what it records with. The inputs themselves are chosen in the Recording menu or Settings.
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
                headline("Downloading Model…", detail: environment.model.displayName)
                ProgressView(value: progress) {
                    EmptyView()
                } currentValueLabel: {
                    Text(
                        ProgressText.detail(progress: progress, remaining: coordinator.timeRemaining)
                    )
                    .monospacedDigit()
                }
                .frame(maxWidth: 320)
                Button("Cancel Download") { coordinator.cancelPreparation() }
                    .controlSize(.large)

            case .recording(let startedAt):
                Text(startedAt, style: .timer)
                    .font(.system(size: 48, weight: .light).monospacedDigit())
                RecordButton(isRecording: true) {
                    Task { await coordinator.stopRecording() }
                }
                caption("Recording · click to stop")
                InputLevelsView(coordinator: coordinator)

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
                // After a failed download, recording still needs the model.
                if coordinator.isModelDownloaded {
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
        let isUnavailable = notesFolder.status != .notChosen

        headline(
            NotesFolderWarning.title(for: notesFolder.status) ?? "",
            detail: NotesFolderWarning.message(for: notesFolder.status, hasLegacyNotes: notesFolder.hasLegacyNotes)
        )
        HStack {
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
