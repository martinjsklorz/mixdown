import MixdownCore
import MixdownMLXLLM
import SwiftUI

/// Whether notes are summarized, the model that summarizes them, and the template for manual
/// recordings and for detected calls.
struct SummarySettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingDelete = false

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

            Section {
                LabeledContent("Model") {
                    HStack {
                        Picker(
                            "Model",
                            selection: Binding(
                                get: { environment.summaryModel },
                                set: { environment.setSummaryModel($0) }
                            )
                        ) {
                            Text(SummaryModel.appleIntelligence.label)
                                .tag(SummaryModel.appleIntelligence)
                            Section("Open models: downloaded once, run on this Mac") {
                                ForEach(SummaryModel.all.filter { !$0.isManagedBySystem }) { model in
                                    menuTitle(for: model)
                                        .tag(model)
                                }
                            }
                        }
                        .labelsHidden()
                        .fixedSize()

                        // macOS push buttons drop the icon unless asked to show it.
                        downloadAccessory
                            .labelStyle(.titleAndIcon)
                    }
                }
                modelStatus
            } header: {
                Text("Model")
            } footer: {
                Text(modelFooter)
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

    /// The model's label, followed by a green check for models on disk, as for speech models.
    private func menuTitle(for model: SummaryModel) -> Text {
        let isDownloaded: Bool =
            switch model {
            case environment.summaryModel: environment.isSummaryModelDownloaded
            case .mlx(let model): MLXSummarizer.isDownloaded(model)
            case .appleIntelligence: false
            }
        guard isDownloaded else { return Text(model.label) }
        return Text("\(model.label)  \(Image(nsImage: TranscriptionSettingsView.downloadedImage))")
            .accessibilityLabel("\(model.label), downloaded")
    }

    /// A row under the model while it downloads or after a download failed.
    @ViewBuilder
    private var modelStatus: some View {
        if let progress = environment.summaryModelProgress {
            ProgressView(value: progress) {
                Text("Downloading \(environment.summaryModel.displayName)…")
            } currentValueLabel: {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            }
        } else if let error = environment.summaryModelError {
            Text(error)
                .foregroundStyle(.red)
        }
    }

    /// Download while an open model isn't on disk, Cancel while it downloads, Delete once it's
    /// there. Nothing for Apple's model, which macOS provides.
    @ViewBuilder
    private var downloadAccessory: some View {
        if environment.summaryModel.isManagedBySystem {
            EmptyView()
        } else if environment.summaryModelProgress != nil {
            Button("Cancel", systemImage: "xmark.circle") { environment.cancelSummaryModelDownload() }
        } else if environment.isDeletingSummaryModel {
            ProgressView()
                .controlSize(.small)
        } else if environment.isSummaryModelDownloaded {
            Button("Delete", systemImage: "trash") { isConfirmingDelete = true }
                .labelStyle(.iconOnly)
                .help("Delete \(environment.summaryModel.displayName)")
                // Not while a summary may be using it.
                .disabled(!environment.canChangeModel)
                .confirmationDialog(
                    "Delete \(environment.summaryModel.displayName)?",
                    isPresented: $isConfirmingDelete
                ) {
                    Button("Delete", role: .destructive) {
                        Task { await environment.deleteSummaryModel() }
                    }
                } message: {
                    Text("This frees up disk space. You'll need to download the model again to get summaries.")
                }
        } else {
            Button("Download", systemImage: "arrow.down.circle") { environment.downloadSummaryModel() }
        }
    }

    /// What a summary is and who makes it, or why it can't be made right now.
    private var footer: String {
        switch environment.summaryAvailability {
        case .available:
            return "Adds a summary above the transcript and names the note after its topic. 1:1, Standup "
                + "and Client Call always have TL;DR, Decisions, Action Items and Open Questions. Detected "
                + "calls are recordings started from a call notification or automatically. "
                + "\(environment.summarizer.info.displayName) makes summaries on this Mac."
        case .unavailable(let reason):
            return reason
        }
    }

    private var modelFooter: String {
        switch environment.summaryModel {
        case .appleIntelligence:
            return "Apple Intelligence is part of macOS and needs to be turned on in System Settings. "
                + "Open models such as Qwen are downloaded once from Hugging Face and need no Apple "
                + "Intelligence. Summaries and Catch Me Up always run on this Mac."
        case .mlx(let model):
            return "\(model.displayName) is a \(model.downloadSize) download from Hugging Face and needs "
                + "about that much memory while it summarizes. Larger models write better summaries but "
                + "are slower. Summaries and Catch Me Up always run on this Mac; Chat uses Apple "
                + "Intelligence."
        }
    }
}
