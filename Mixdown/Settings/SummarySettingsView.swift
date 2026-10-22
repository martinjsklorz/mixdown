import MixdownCore
import SwiftUI

/// Whether notes are summarized, and the template for manual recordings and for detected calls.
struct SummarySettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Summarize recordings",
                    isOn: Binding(
                        get: { environment.summarizesNotes },
                        set: { environment.summarizesNotes = $0 }
                    )
                )
                Group {
                    templatePicker(
                        "Manual recordings",
                        selection: Binding(
                            get: { environment.summaryTemplate },
                            set: { environment.summaryTemplate = $0 }
                        )
                    )
                    templatePicker(
                        "Detected calls",
                        selection: Binding(
                            get: { environment.callSummaryTemplate },
                            set: { environment.callSummaryTemplate = $0 }
                        )
                    )
                }
                .disabled(!environment.summarizesNotes)
            } footer: {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func templatePicker(_ title: String, selection: Binding<SummaryTemplate>) -> some View {
        Picker(title, selection: selection) {
            ForEach(SummaryTemplate.allCases) { template in
                Text(template.displayName).tag(template)
            }
        }
    }

    /// What a summary is and who makes it, or why it can't be made right now.
    private var footer: String {
        let summarizer = environment.summarizer
        switch summarizer.availability {
        case .available:
            return "Adds a summary above the transcript and names the note after its topic. 1:1, Standup "
                + "and Client Call always have TL;DR, Decisions, Action Items and Open Questions. Detected "
                + "calls are recordings started from a call notification or automatically. "
                + "\(summarizer.info.displayName) makes summaries on this Mac."
        case .unavailable(let reason):
            return reason
        }
    }
}
