import MixdownCore
import MixdownSpeechSwift
import SwiftUI

struct TranscriptionSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

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
                    ForEach(SpeechSwiftModel.allCases) { model in
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
            } footer: {
                Text(footer(for: environment.model))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                HStack {
                    modelStatus(for: coordinator.phase)
                    Spacer()
                    Button("Download Model Now") {
                        Task { await coordinator.prepareEngine() }
                    }
                    .disabled(!environment.canChangeModel)
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

    private func footer(for model: SpeechSwiftModel) -> String {
        var lines = [
            "Larger models are more accurate but slower and take more disk space.",
            "Models are downloaded once from Hugging Face; transcription always runs on this Mac.",
        ]
        if model.labelsSpeakers {
            lines.append("This model labels speakers and detects the language automatically.")
        }
        return lines.joined(separator: " ")
    }

    private static func displayName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
