import MixdownCore
import MixdownMLXLLM
import SwiftUI

/// Whether notes are summarized, the model that summarizes them, and the template for manual
/// recordings and for detected calls.
struct SummarySettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    private var preferences: Preferences { environment.preferences }
    @Environment(MainNavigation.self) private var navigation
    @State private var isConfirmingDelete = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Summarize recordings",
                    isOn: Binding(
                        get: { preferences.summarizesNotes },
                        set: { preferences.summarizesNotes = $0 }
                    )
                )
            } footer: {
                Caption(footer)
            }

            Section {
                templatePicker(
                    "Manual recordings",
                    selection: Binding(
                        get: { preferences.summaryTemplates.recordingTemplate },
                        set: { preferences.summaryTemplates.recordingTemplate = $0 }
                    )
                )
                templatePicker(
                    "Detected calls",
                    selection: Binding(
                        get: { preferences.summaryTemplates.callTemplate },
                        set: { preferences.summaryTemplates.callTemplate = $0 }
                    )
                )
                Button("Edit Templates…") { navigation.settingsTab = .templates }
            } header: {
                Text("Templates")
            } footer: {
                Caption(
                    "Detected calls are recordings started from a call notification or automatically. "
                        + "Change what each template looks out for, or add your own, under Templates."
                )
            }
            .disabled(!preferences.summarizesNotes)

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
                Caption(modelFooter)
            }
        }
        .formStyle(.grouped)
    }

    private func templatePicker(_ title: String, selection: Binding<SummaryTemplate>) -> some View {
        Picker(
            title,
            selection: Binding(
                get: { selection.wrappedValue.id },
                set: { selection.wrappedValue = preferences.summaryTemplates.template(id: $0) }
            )
        ) {
            ForEach(preferences.summaryTemplates.templates) { template in
                Text(template.displayName).tag(template.id)
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
        return Text("\(model.label)  \(Image(nsImage: DownloadedBadge.image))")
            .accessibilityLabel("\(model.label), downloaded")
    }

    /// A row under the model while it downloads or after a download failed.
    @ViewBuilder
    private var modelStatus: some View {
        if let progress = environment.summaryModelDownload?.progress {
            ProgressView(value: progress) {
                Text("Downloading \(environment.summaryModel.displayName)…")
            } currentValueLabel: {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            }
        } else if let error = environment.summaryModelDownload?.error {
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
        } else if environment.summaryModelDownload?.progress != nil {
            Button("Cancel", systemImage: "xmark.circle") { environment.summaryModelDownload?.cancel() }
        } else if environment.summaryModelDownload?.isDeleting == true {
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
                        Task { await environment.summaryModelDownload?.delete() }
                    }
                } message: {
                    Text("This frees up disk space. You'll need to download the model again to get summaries.")
                }
        } else {
            Button("Download", systemImage: "arrow.down.circle") { environment.summaryModelDownload?.start() }
        }
    }

    /// What a summary is and who makes it, or why it can't be made right now.
    private var footer: String {
        switch environment.summaryAvailability {
        case .available:
            return "Adds a summary above the transcript and names the note after its topic. "
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
