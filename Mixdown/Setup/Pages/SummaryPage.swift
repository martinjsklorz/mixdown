import MixdownCore
import MixdownMLXLLM
import SwiftUI

/// The setup assistant's page for summaries: whether to write one, and with which model. An open
/// model is downloaded on the last page.
struct SummaryPage: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let preferences = environment.preferences
        let summaryModel = environment.summaryModel

        SetupPage(
            title: "Summaries",
            systemImage: "list.bullet.rectangle",
            detail: "Mixdown can write a summary above each transcript and name the note after its "
                + "topic, with a language model that runs on this Mac."
        ) {
            Form {
                Section {
                    Toggle(
                        "Summarize recordings",
                        isOn: Bindable(preferences).summarizesNotes
                    )
                }

                if preferences.summarizesNotes {
                    Section {
                        SetupChoice(
                            title: "Apple Intelligence",
                            systemImage: "apple.intelligence",
                            detail: "Built into macOS, nothing to download. Needs Apple Intelligence "
                                + "turned on in System Settings.",
                            isSelected: summaryModel == .appleIntelligence
                        ) {
                            environment.setSummaryModel(.appleIntelligence)
                        }
                        SetupChoice(
                            title: "Open Model",
                            systemImage: "shippingbox",
                            detail: "Qwen, downloaded once from Hugging Face. Works without Apple "
                                + "Intelligence.",
                            isSelected: summaryModel != .appleIntelligence
                        ) {
                            guard summaryModel == .appleIntelligence else { return }
                            environment.setSummaryModel(.mlx(.default))
                        }

                        if case .mlx(let model) = summaryModel {
                            Picker(
                                "Model",
                                selection: Binding(
                                    get: { model },
                                    set: { environment.setSummaryModel(.mlx($0)) }
                                )
                            ) {
                                ForEach(MLXLanguageModel.allCases) { model in
                                    Text("\(model.purpose) · \(model.displayName) (\(model.downloadSize))")
                                        .tag(model)
                                }
                            }
                        }
                    } footer: {
                        Caption(modelFooter, isWarning: isUnavailable)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    /// Whether Apple Intelligence can't summarize, e.g. as it's turned off. An open model that
    /// isn't downloaded yet will be on the last page, so that doesn't count.
    private var isUnavailable: Bool {
        guard environment.summaryModel == .appleIntelligence,
            case .unavailable = environment.summaryAvailability
        else { return false }
        return true
    }

    private var modelFooter: String {
        if environment.summaryModel == .appleIntelligence,
            case .unavailable(let reason) = environment.summaryAvailability
        {
            return reason + " Or pick an open model."
        }
        return "Larger models write better summaries but are slower. Change it any time under "
            + "Settings → Summary, which also has templates for 1:1s, standups and client calls."
    }
}
