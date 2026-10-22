import MixdownCore
import SwiftUI

/// The setup assistant's page for picking and downloading the speech model.
struct ModelPage: View {
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
                            Text(model.menuLabel).tag(model)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .disabled(!environment.canChangeModel)

                    LanguagePicker()
                } footer: {
                    Caption(footer(for: environment.model))
                }

                Section {
                    status(for: coordinator)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func footer(for model: TranscriptionModel) -> String {
        if model.labelsSpeakers {
            "This model labels speakers and detects the language itself."
        } else if model.isManagedBySystem {
            "Apple's model is part of macOS. Automatic uses your Mac's language."
        } else if model.isLive {
            "The live model shows the text as you speak, and the note is ready when you stop. Change "
                + "it later under Settings → Transcription."
        } else {
            "Larger models are more accurate but slower. Change it later under Settings → Transcription."
        }
    }

    @ViewBuilder
    private func status(for coordinator: RecordingCoordinator) -> some View {
        if case .preparingModel(let progress) = coordinator.phase {
            HStack(alignment: .bottom, spacing: 12) {
                ModelDownloadProgress(progress: progress)
                Button("Cancel") { coordinator.cancelPreparation() }
                    .disabled(!coordinator.canCancelPreparation)
            }
            Caption("You can go on while it downloads. The menu bar shows the time left.")
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
            Caption(modelError, isWarning: true)
        }
    }
}
