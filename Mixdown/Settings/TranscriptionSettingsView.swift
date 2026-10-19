import AppKit
import MixdownAppleSpeech
import MixdownCore
import SwiftUI

struct TranscriptionSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingDelete = false
    /// Whether macOS has Apple's speech model for the chosen language, for the model menu while
    /// another model is selected. macOS only says so asynchronously.
    @State private var isAppleSpeechInstalled = false

    /// ISO 639-1 codes offered besides "Automatic". The models support many more.
    static let languages = ["en", "de", "fr", "es", "it", "pt", "nl", "pl", "ja", "zh"]

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
            } header: {
                Text("Summary")
            } footer: {
                Text(summaryFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: environment.language) {
            isAppleSpeechInstalled = await AppleSpeechEngine.isInstalled(language: environment.language)
        }
    }

    /// A row under the model while it downloads or after it failed; nothing otherwise, as the
    /// model menu marks downloaded models.
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
            }
        }
    }

    /// The model's name, followed by a green check for models on disk, so the menu says which
    /// models are ready without picking them. Nothing for models not downloaded yet.
    private func menuTitle(for model: TranscriptionModel) -> Text {
        let isDownloaded =
            model == environment.model
            ? environment.coordinator.isModelDownloaded
            : model.isDownloaded ?? isAppleSpeechInstalled
        let label = Self.label(for: model)
        guard isDownloaded else { return Text(label) }
        return Text("\(label)  \(Image(nsImage: Self.downloadedImage))")
            .accessibilityLabel("\(label), downloaded")
    }

    /// `checkmark.circle.fill` in green. Menus draw SF Symbols as monochrome templates, so the
    /// colors are baked into a non-template image. Menus also put a plain image's bottom on the
    /// baseline and ignore a baseline offset, so the symbol's padding is cropped off and the circle
    /// sized to the menu font's cap height: it then spans baseline to cap height, like the digits.
    private static let downloadedImage: NSImage = {
        let font = NSFont.menuFont(ofSize: 0)
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemGreen]))
        guard
            let symbol = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        else { return NSImage() }
        symbol.isTemplate = false
        let glyph = symbol.alignmentRect
        guard glyph.height > 0 else { return symbol }
        let scale = font.capHeight / glyph.height
        let size = NSSize(width: (glyph.width * scale).rounded(.up), height: font.capHeight)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(
                in: NSRect(
                    x: -glyph.minX * scale,
                    y: -glyph.minY * scale,
                    width: symbol.size.width * scale,
                    height: symbol.size.height * scale
                )
            )
            return true
        }
        image.accessibilityDescription = "Downloaded"
        return image
    }()

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

    private func templatePicker(_ title: String, selection: Binding<SummaryTemplate>) -> some View {
        Picker(title, selection: selection) {
            ForEach(SummaryTemplate.allCases) { template in
                Text(template.displayName).tag(template)
            }
        }
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
    static func label(for model: TranscriptionModel) -> String {
        model.purpose.map { "\($0) · \(model.displayName)" } ?? model.displayName
    }

    /// What a summary is and who makes it, or why it can't be made right now.
    private var summaryFooter: String {
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

    static func displayName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
