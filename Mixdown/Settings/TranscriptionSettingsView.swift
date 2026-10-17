import MixdownCore
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
                    ForEach(TranscriptionModel.available) { model in
                        Text(model.displayName).tag(model)
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
            } header: {
                Text("Settings")
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

            Section {
                TextField(
                    "Microphone",
                    text: Binding(
                        get: { environment.sourceLabels.microphone },
                        set: { environment.sourceLabels.microphone = $0 }
                    ),
                    prompt: Text(SourceLabels.defaultMicrophone)
                )
                TextField(
                    "System audio",
                    text: Binding(
                        get: { environment.sourceLabels.systemAudio },
                        set: { environment.sourceLabels.systemAudio = $0 }
                    ),
                    prompt: Text(SourceLabels.defaultSystemAudio)
                )
            } header: {
                Text("Speaker Names")
            } footer: {
                Text(
                    "With more than one input, each is transcribed on its own and its lines are labeled "
                        + "with these names. Use headphones so your microphone doesn't pick up the other "
                        + "people; otherwise Mixdown drops lines your microphone only heard from the speakers."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Summarize recordings",
                    isOn: Binding(
                        get: { environment.summarizesNotes },
                        set: { environment.summarizesNotes = $0 }
                    )
                )
            } header: {
                Text("Summary")
            } footer: {
                Text(summaryFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    ProgressText.detail(
                        progress: progress,
                        remaining: environment.coordinator.timeRemaining
                    )
                )
                .monospacedDigit()
            }
        default:
            // Other failures, such as a missing microphone permission, aren't the model's; the main
            // window shows those.
            if let modelError = environment.coordinator.modelError {
                Text(modelError)
                    .foregroundStyle(.red)
            } else {
                Text(environment.coordinator.engineInfo.displayName)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "Downloaded" and a Delete button once the model is on disk, otherwise a button to fetch it;
    /// recording needs it. A Cancel button while preparing (files land on disk mid-download, so
    /// "Downloaded" would be premature). After a model error, Retry and Delete for files on disk
    /// (they may be broken), else Download. No Delete for a model macOS manages.
    @ViewBuilder
    private func downloadAccessory(for phase: RecordingCoordinator.Phase) -> some View {
        switch phase {
        case .preparingModel:
            Button("Cancel", systemImage: "xmark.circle") { environment.coordinator.cancelPreparation() }
        default:
            if environment.coordinator.isDeletingModel {
                ProgressView()
                    .controlSize(.small)
            } else if environment.coordinator.isModelDownloaded, environment.coordinator.modelError != nil {
                Button("Retry", systemImage: "arrow.clockwise") { prepare() }
                    .disabled(!environment.canChangeModel)
                if !environment.model.isManagedBySystem { deleteButton }
            } else if environment.coordinator.isModelDownloaded {
                Label {
                    Text("Downloaded")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .foregroundStyle(.secondary)
                // macOS decides when to remove its own model.
                if !environment.model.isManagedBySystem { deleteButton }
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
        Button("Download", systemImage: "arrow.down.circle") { prepare() }
            .disabled(!environment.canChangeModel)
    }

    private func prepare() {
        Task { await environment.coordinator.prepareEngine() }
    }

    private func footer(for model: TranscriptionModel) -> String {
        if model.isManagedBySystem {
            return "Apple's speech model is part of macOS. It's downloaded from Apple once per language and "
                + "shared with other apps, and transcription runs on this Mac. Automatic uses your Mac's "
                + "language. This model doesn't label speakers."
        }
        var lines = [
            "Larger models are more accurate but slower and take more disk space.",
            "Models are downloaded once from Hugging Face; transcription always runs on this Mac.",
        ]
        if model.labelsSpeakers {
            lines.append("This model labels speakers and detects the language automatically.")
        }
        return lines.joined(separator: " ")
    }

    /// What a summary is and who makes it, or why it can't be made right now.
    private var summaryFooter: String {
        let summarizer = environment.summarizer
        switch summarizer.availability {
        case .available:
            return "Adds an overview, key points and action items above the transcript, and names the note "
                + "after its topic. \(summarizer.info.displayName) makes them on this Mac."
        case .unavailable(let reason):
            return reason
        }
    }

    static func displayName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
