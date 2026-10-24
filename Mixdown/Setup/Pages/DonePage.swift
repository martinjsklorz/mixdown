import KeyboardShortcuts
import MixdownCore
import SwiftUI

/// The setup assistant's last page: what's ready, and the models the choices before need, which
/// the assistant's Download button fetches. Downloads carry on once the assistant is closed.
struct DonePage: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(MainNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SetupPage(
            title: environment.needsSetupDownloads ? "Almost There" : "You're All Set",
            systemImage: environment.needsSetupDownloads ? "arrow.down.circle" : "checkmark.seal",
            detail: environment.needsSetupDownloads
                ? "Download the models you picked. They're fetched once and run on this Mac."
                : startHint
        ) {
            Form {
                Section {
                    row("Notes folder", systemImage: "folder", isReady: environment.notesFolder.directory != nil) {
                        Text(environment.notesFolder.status.name ?? "Not chosen")
                    }
                    row("Inputs", systemImage: "mic", isReady: !environment.coordinator.selectedDevices.isEmpty) {
                        Text(inputsName)
                    }
                }

                Section {
                    speechModelRow
                    if environment.preferences.identifiesSpeakers {
                        downloadRow(
                            "Speakers",
                            systemImage: "person.2.wave.2",
                            name: "Nemotron 3 Diarization (100 MB)",
                            download: environment.speakerModelDownload
                        )
                    }
                    if environment.preferences.summarizesNotes {
                        summaryModelRow
                    }
                } header: {
                    Text("Models")
                } footer: {
                    HStack(alignment: .firstTextBaseline) {
                        Caption(modelsFooter)
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

    // MARK: Rows

    @ViewBuilder
    private var speechModelRow: some View {
        let coordinator = environment.coordinator

        row("Speech", systemImage: "waveform", isReady: coordinator.isModelDownloaded) {
            if case .preparingModel(let progress) = coordinator.phase {
                percent(progress)
            } else {
                Text(environment.model.displayName)
            }
        }
        if let modelError = coordinator.modelError {
            Caption(modelError, isWarning: true)
        }
    }

    @ViewBuilder
    private var summaryModelRow: some View {
        switch environment.summaryModel {
        case .appleIntelligence:
            let availability = environment.summaryAvailability
            row("Summaries", systemImage: "list.bullet.rectangle", isReady: availability == .available) {
                Text("Apple Intelligence")
            }
            if case .unavailable(let reason) = availability {
                Caption(reason, isWarning: true)
            }
        case .mlx(let model):
            if let download = environment.summaryModelDownload {
                downloadRow(
                    "Summaries",
                    systemImage: "list.bullet.rectangle",
                    name: "\(model.displayName) (\(model.downloadSize))",
                    download: download
                )
            }
        }
    }

    /// A model kept on disk by `download`: its progress while downloading, why it failed.
    @ViewBuilder
    private func downloadRow(
        _ title: String,
        systemImage: String,
        name: String,
        download: ModelDownload
    ) -> some View {
        row(title, systemImage: systemImage, isReady: download.isDownloaded) {
            if let progress = download.progress {
                percent(progress)
            } else {
                Text(name)
            }
        }
        if let error = download.error {
            Caption(error, isWarning: true)
        }
    }

    private func percent(_ progress: Double) -> some View {
        Text("Downloading, \(progress.formatted(.percent.precision(.fractionLength(0))))")
            .monospacedDigit()
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

    // MARK: Text

    private var modelsFooter: String {
        if environment.needsSetupDownloads {
            "Downloads carry on in the background once you start using Mixdown. Everything here is "
                + "in Settings too."
        } else if environment.isDownloadingSetupModels {
            "You can start using Mixdown now. The downloads carry on in the background."
        } else {
            "Everything here is in Settings too."
        }
    }

    /// How to start recording, with the global shortcut if it's on.
    private var startHint: String {
        let inApp = "Click the red button in Record, or press ⌘R, to start recording."
        guard environment.preferences.isRecordingShortcutEnabled,
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

// MARK: - Downloads

extension AppEnvironment {
    /// Whether a model the settings call for is neither on disk nor downloading: the speech
    /// model, the speaker model while telling speakers apart, and an open summary model while
    /// summarizing.
    var needsSetupDownloads: Bool {
        needsSpeechModel || needsSpeakerModel || needsSummaryModel
    }

    /// Whether any of those models is downloading.
    var isDownloadingSetupModels: Bool {
        if case .preparingModel = coordinator.phase { return true }
        return speakerModelDownload.progress != nil || summaryModelDownload?.progress != nil
    }

    /// Downloads every model `needsSetupDownloads` counts, side by side.
    func startSetupDownloads() {
        if needsSpeechModel {
            let coordinator = coordinator
            Task { await coordinator.prepareEngine() }
        }
        if needsSpeakerModel { speakerModelDownload.start() }
        if needsSummaryModel { summaryModelDownload?.start() }
    }

    private var needsSpeechModel: Bool {
        !coordinator.isModelDownloaded && coordinator.isIdle
    }

    private var needsSpeakerModel: Bool {
        preferences.identifiesSpeakers && !speakerModelDownload.isDownloaded
            && speakerModelDownload.progress == nil
    }

    private var needsSummaryModel: Bool {
        guard preferences.summarizesNotes, let download = summaryModelDownload else { return false }
        return !download.isDownloaded && download.progress == nil
    }
}
