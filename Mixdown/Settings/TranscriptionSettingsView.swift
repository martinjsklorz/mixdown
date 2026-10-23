import MixdownAppleSpeech
import MixdownCore
import SwiftUI

struct TranscriptionSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    private var preferences: Preferences { environment.preferences }
    @State private var isConfirmingDelete = false
    @State private var isConfirmingSpeakerModelDelete = false
    /// Whether macOS has Apple's speech model for the chosen language, for the model menu while
    /// another model is selected. macOS only says so asynchronously.
    @State private var isAppleSpeechInstalled = false

    var body: some View {
        let coordinator = environment.coordinator

        Form {
            Section {
                LabeledContent("Model") {
                    HStack {
                        Picker(
                            "Model",
                            selection: Binding(
                                get: { environment.model },
                                set: { environment.setModel($0) }
                            )
                        ) {
                            Section("Offline: transcribed when you stop") {
                                ForEach(TranscriptionModel.available.filter { !$0.isLive }) { model in
                                    menuTitle(for: model)
                                        .tag(model)
                                }
                            }
                            Section("Live: transcribed while you record") {
                                ForEach(TranscriptionModel.available.filter(\.isLive)) { model in
                                    menuTitle(for: model)
                                        .tag(model)
                                }
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!environment.canChangeModel)

                        // macOS push buttons drop the icon unless asked to show it.
                        downloadAccessory(for: coordinator.phase)
                            .labelStyle(.titleAndIcon)
                    }
                }

                modelStatus(for: coordinator.phase)

                LanguagePicker()
            } header: {
                Text("Settings")
            } footer: {
                Caption(footer(for: environment.model))
            }

            Section {
                TextField(
                    "Microphone",
                    text: Binding(
                        get: { preferences.sourceLabels.microphone },
                        set: { preferences.sourceLabels.microphone = $0 }
                    ),
                    prompt: Text(SourceLabels.defaultMicrophone)
                )
                TextField(
                    "System audio",
                    text: Binding(
                        get: { preferences.sourceLabels.systemAudio },
                        set: { preferences.sourceLabels.systemAudio = $0 }
                    ),
                    prompt: Text(SourceLabels.defaultSystemAudio)
                )
            } header: {
                Text("Speaker Names")
            } footer: {
                Caption(
                    "With more than one input, each is transcribed on its own and its lines are labeled "
                        + "with these names. Use headphones so your microphone doesn't pick up the other "
                        + "people; otherwise Mixdown drops lines your microphone only heard from the speakers."
                )
            }

            Section {
                Toggle(
                    "Tell speakers apart",
                    isOn: Binding(
                        get: { preferences.identifiesSpeakers },
                        set: { environment.setIdentifiesSpeakers($0) }
                    )
                )
                speakerModelStatus
                Toggle(
                    "Name speakers from the conversation",
                    isOn: Binding(
                        get: { preferences.namesSpeakers },
                        set: { preferences.namesSpeakers = $0 }
                    )
                )
                .disabled(!preferences.identifiesSpeakers)
            } header: {
                Text("Speakers")
            } footer: {
                Caption(speakersFooter)
            }
        }
        .formStyle(.grouped)
        .task(id: preferences.language) {
            isAppleSpeechInstalled = await AppleSpeechEngine.isInstalled(language: preferences.language)
        }
    }

    /// A row under the model while it downloads or after it failed; nothing otherwise, as the
    /// model menu marks downloaded models.
    @ViewBuilder
    private func modelStatus(for phase: RecordingCoordinator.Phase) -> some View {
        switch phase {
        case .preparingModel(let progress):
            ModelDownloadProgress(progress: progress)
        default:
            // Other failures, such as a missing microphone permission, aren't the model's; the main
            // window shows those.
            if let modelError = environment.coordinator.modelError {
                Text(modelError)
                    .foregroundStyle(.red)
            }
        }
    }

    /// The speaker model's download progress, why it failed, or Download while it's missing;
    /// Delete once it's on disk.
    @ViewBuilder
    private var speakerModelStatus: some View {
        if let progress = environment.speakerModelDownload.progress {
            HStack {
                ProgressView(value: progress) {
                    Text("Downloading the speaker model…")
                } currentValueLabel: {
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                }
                Button("Cancel", systemImage: "xmark.circle") { environment.speakerModelDownload.cancel() }
                    .labelStyle(.iconOnly)
                    .help("Cancel")
            }
        } else if let error = environment.speakerModelDownload.error {
            HStack {
                Text(error)
                    .foregroundStyle(.red)
                Spacer()
                Button("Retry", systemImage: "arrow.clockwise") { environment.speakerModelDownload.start() }
                    .labelStyle(.titleAndIcon)
            }
        } else if environment.speakerModelDownload.isDeleting {
            LabeledContent("Speaker model") {
                ProgressView()
                    .controlSize(.small)
            }
        } else if environment.speakerModelDownload.isDownloaded {
            LabeledContent("Speaker model") {
                Button("Delete", systemImage: "trash") { isConfirmingSpeakerModelDelete = true }
                    .labelStyle(.iconOnly)
                    .help("Delete the speaker model")
                    // Not while a recording may need it.
                    .disabled(!environment.canChangeModel)
                    .confirmationDialog(
                        "Delete the speaker model?",
                        isPresented: $isConfirmingSpeakerModelDelete
                    ) {
                        Button("Delete", role: .destructive) {
                            Task { await environment.deleteSpeakerModel() }
                        }
                    } message: {
                        Text("This frees up disk space and turns off telling speakers apart.")
                    }
            }
        } else if preferences.identifiesSpeakers {
            LabeledContent("Speaker model") {
                Button("Download", systemImage: "arrow.down.circle") { environment.speakerModelDownload.start() }
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private var speakersFooter: String {
        var lines = [
            "Once a recording ends, Mixdown tells the people on the system audio apart by their voices and labels "
                + "their lines Speaker 1, Speaker 2 and so on. Your microphone keeps its name.",
            "The speaker model, Nemotron 3 Diarization, is downloaded once from Hugging Face (about 100 MB) and runs "
                + "on this Mac.",
        ]
        if environment.model.isLive {
            lines.append("With the live model, the system audio is kept in memory until you stop.")
        }
        lines.append(
            "Naming them uses \(environment.summarizer.info.displayName), your summary model: it looks for "
                + "names said in the conversation, such as people introducing themselves or being asked by "
                + "name. A speaker it can't tell stays numbered."
        )
        if preferences.namesSpeakers, case .unavailable(let reason) = environment.summaryAvailability {
            lines.append(reason)
        }
        return lines.joined(separator: " ")
    }

    /// The model's name, followed by a green check for models on disk, so the menu says which
    /// models are ready without picking them. Nothing for models not downloaded yet.
    private func menuTitle(for model: TranscriptionModel) -> Text {
        let isDownloaded =
            model == environment.model
            ? environment.coordinator.isModelDownloaded
            : model.isDownloaded ?? isAppleSpeechInstalled
        let label = model.menuLabel
        guard isDownloaded else { return Text(label) }
        return Text("\(label)  \(Image(nsImage: DownloadedBadge.image))")
            .accessibilityLabel("\(label), downloaded")
    }

    /// Download next to the model menu while the model isn't on disk, Delete once it is; recording
    /// needs it. A Cancel button while preparing (files land on disk mid-download, so the menu's
    /// check would be premature). After a model error, Retry and Delete for files on disk (they may
    /// be broken), else Download. No Delete for a model macOS manages.
    @ViewBuilder
    private func downloadAccessory(for phase: RecordingCoordinator.Phase) -> some View {
        switch phase {
        case .preparingModel:
            // A download for a finished recording can't be cancelled.
            if !environment.coordinator.isPreparingModelForRecording {
                Button("Cancel", systemImage: "xmark.circle") { environment.coordinator.cancelPreparation() }
                    .disabled(!environment.coordinator.canCancelPreparation)
            }
        default:
            if environment.coordinator.isDeletingModel {
                ProgressView()
                    .controlSize(.small)
            } else if environment.coordinator.isModelDownloaded, environment.coordinator.modelError != nil {
                Button("Retry", systemImage: "arrow.clockwise") { prepare() }
                    .disabled(!environment.canChangeModel)
                if !environment.model.isManagedBySystem { deleteButton }
            } else if environment.coordinator.isModelDownloaded {
                // macOS decides when to remove its own model.
                if !environment.model.isManagedBySystem {
                    deleteButton
                        .labelStyle(.iconOnly)
                        .help("Delete \(environment.model.displayName)")
                }
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
        var lines: [String]
        if model.isLive {
            lines = [
                preferences.identifiesSpeakers
                    ? "The live model shows the text as you speak and saves it as the note, so the note is ready when you stop."
                    : "The live model shows the text as you speak and saves it as the note, so the note is ready when you stop and no audio is kept, however long you record.",
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
}
