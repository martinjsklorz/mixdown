import MixdownSpeechSwift
import SwiftUI

/// The setup assistant's page for how speech becomes text: live while recording, or once it
/// stops, and whether to tell speakers apart. Nothing is downloaded until the last page.
struct TranscriptionPage: View {
    @Environment(AppEnvironment.self) private var environment
    /// The offline model to go back to after trying the live one.
    @State private var offlineModel: TranscriptionModel?

    var body: some View {
        let model = environment.model
        let preferences = environment.preferences

        SetupPage(
            title: "How to Transcribe",
            systemImage: "text.bubble",
            detail: "Speech is turned into text on this Mac, either while you record or once you stop."
        ) {
            Form {
                Section {
                    SetupChoice(
                        title: "Live",
                        systemImage: "text.word.spacing",
                        detail: "See the text as you speak. The note is ready the moment you stop, but "
                            + "it's less accurate.",
                        isSelected: model.isLive
                    ) {
                        if !model.isLive { offlineModel = model }
                        if let live = TranscriptionModel.available.first(where: \.isLive) {
                            environment.setModel(live)
                        }
                    }
                    SetupChoice(
                        title: "When You Stop",
                        systemImage: "hourglass",
                        detail: "The whole recording is transcribed at the end. More accurate, and the "
                            + "note takes a little while.",
                        isSelected: !model.isLive
                    ) {
                        guard model.isLive else { return }
                        environment.setModel(offlineModel ?? Self.defaultOfflineModel)
                    }
                } footer: {
                    if !environment.canChangeModel {
                        Caption("The model can't change while it's downloading or recording.")
                    }
                }
                .disabled(!environment.canChangeModel)

                Section {
                    if !model.isLive {
                        Picker(
                            "Model",
                            selection: Binding(
                                get: { environment.model },
                                set: { environment.setModel($0) }
                            )
                        ) {
                            ForEach(TranscriptionModel.available.filter { !$0.isLive }) { model in
                                Text(model.menuLabel).tag(model)
                            }
                        }
                        .disabled(!environment.canChangeModel)
                    }
                    LanguagePicker()
                } footer: {
                    Caption(modelFooter(for: model))
                }

                Section {
                    Toggle(
                        "Tell speakers apart",
                        isOn: Binding(
                            get: { preferences.identifiesSpeakers },
                            // Downloaded on the last page with the rest; turning it off stops a
                            // download already under way.
                            set: { enabled in
                                if enabled {
                                    preferences.identifiesSpeakers = true
                                } else {
                                    environment.setIdentifiesSpeakers(false)
                                }
                            }
                        )
                    )
                } footer: {
                    Caption(
                        "Labels the other people on a call Speaker 1, Speaker 2 and so on, once the "
                            + "recording ends, and names them when they're named in the conversation. "
                            + "Needs a 100 MB model."
                    )
                }
            }
            .formStyle(.grouped)
        }
    }

    /// Accurate without being the slowest, for someone switching away from the live model.
    private static let defaultOfflineModel = TranscriptionModel.speechSwift(.qwen3ASRLarge)

    private func modelFooter(for model: TranscriptionModel) -> String {
        if model.isLive {
            "Uses \(model.displayName). Change models any time under Settings → Transcription."
        } else if model.isManagedBySystem {
            "Apple's model is part of macOS. Automatic uses your Mac's language."
        } else if model.labelsSpeakers {
            "This model labels speakers and detects the language itself."
        } else {
            "Larger models are more accurate but slower. Change it any time under Settings → "
                + "Transcription."
        }
    }
}
