import MixdownCore
import MixdownSpeechSwift
import SwiftUI

struct TranscriptionSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingDelete = false

    /// ISO 639-1 codes offered besides "Automatic". The models support many more.
    private static let languages = ["en", "de", "fr", "es", "it", "pt", "nl", "pl", "ja", "zh"]

    var body: some View {
        let coordinator = environment.coordinator

        Form {
            Section {
                Picker(
                    "Model",
                    selection: Binding(
                        get: { environment.model },
                        set: { environment.setModel($0) }
                    )
                ) {
                    Section("Offline: transcribed when you stop") {
                        ForEach(SpeechSwiftModel.allCases.filter { !$0.isLive }) { model in
                            Text(Self.label(for: model)).tag(model)
                        }
                    }
                    Section("Live: transcribed while you record") {
                        ForEach(SpeechSwiftModel.allCases.filter(\.isLive)) { model in
                            Text(Self.label(for: model)).tag(model)
                        }
                    }
                }
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
                    ForEach(Self.languages, id: \.self) { code in
                        Text(Self.displayName(for: code)).tag(Optional(code))
                    }
                }
                .disabled(!environment.model.supportsLanguageSelection)
            } footer: {
                Text(footer(for: environment.model))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                HStack {
                    modelStatus(for: coordinator.phase)
                    Spacer()
                    // macOS push buttons drop the icon unless asked to show it.
                    downloadAccessory(for: coordinator.phase)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func modelStatus(for phase: RecordingCoordinator.Phase) -> some View {
        switch phase {
        case .preparingModel(let progress):
            ProgressView(value: progress) {
                Text("Downloading \(environment.model.displayName)…")
            } currentValueLabel: {
                Text(
                    DownloadProgressText.detail(
                        progress: progress,
                        remaining: environment.coordinator.preparationTimeRemaining
                    )
                )
                .monospacedDigit()
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
        default:
            Text(environment.coordinator.engineInfo.displayName)
                .foregroundStyle(.secondary)
        }
    }

    /// "Downloaded" and a Delete button once the model is on disk, otherwise a button to fetch it;
    /// recording needs it. A Cancel button while preparing (files land on disk mid-download, so
    /// "Downloaded" would be premature).
    @ViewBuilder
    private func downloadAccessory(for phase: RecordingCoordinator.Phase) -> some View {
        switch phase {
        case .preparingModel:
            Button("Cancel", systemImage: "xmark.circle") { environment.coordinator.cancelPreparation() }
        // A failed load may mean the cached files are broken; offer the button to retry.
        case .failed:
            downloadButton
        default:
            if environment.coordinator.isDeletingModel {
                ProgressView()
                    .controlSize(.small)
            } else if environment.coordinator.isModelDownloaded {
                Label {
                    Text("Downloaded")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .foregroundStyle(.secondary)
                deleteButton
            } else {
                downloadButton
            }
        }
    }

    private var deleteButton: some View {
        Button("Delete", systemImage: "trash") { isConfirmingDelete = true }
            .disabled(!environment.canChangeModel)
            .confirmationDialog(
                "Delete \(environment.model.displayName)?",
                isPresented: $isConfirmingDelete
            ) {
                Button("Delete", role: .destructive) {
                    Task { await environment.coordinator.deleteModel() }
                }
            } message: {
                Text("This frees up disk space. You'll need to download the model again before recording.")
            }
    }

    private var downloadButton: some View {
        Button("Download", systemImage: "arrow.down.circle") {
            Task { await environment.coordinator.prepareEngine() }
        }
        .disabled(!environment.canChangeModel)
    }

    private func footer(for model: SpeechSwiftModel) -> String {
        var lines: [String]
        if model.isLive {
            lines = [
                "The live model shows the text as you speak and saves it as the note, so the note is ready when you stop and no audio is kept, however long you record.",
                "It's less accurate than the offline models and names speakers only by input, like Me and Others.",
            ]
        } else {
            lines = [
                "Offline models transcribe the whole recording once you stop, so its audio is kept in memory until then.",
                "Larger models are more accurate but slower and take more disk space.",
            ]
        }
        if model.labelsSpeakers {
            lines.append("This model labels speakers and detects the language automatically.")
        }
        lines.append("Models are downloaded once from Hugging Face; transcription always runs on this Mac.")
        return lines.joined(separator: " ")
    }

    /// "Low · Qwen3-ASR 0.6B": what the model is for, then which it is.
    static func label(for model: SpeechSwiftModel) -> String {
        "\(model.purpose) · \(model.displayName)"
    }

    static func displayName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
