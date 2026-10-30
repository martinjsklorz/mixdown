import MixdownAppleTranslation
import SwiftUI
import Translation

/// Whether notes are translated, which language into, and whether macOS has the languages to
/// translate the usual recordings.
struct TranslationSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    private var preferences: Preferences { environment.preferences }
    /// BCP 47 identifiers of the languages Apple's models translate between, by name. Empty until
    /// macOS has said.
    @State private var languages: [String] = []
    /// Whether each language can be translated into from `checkedSource`, and is downloaded, by
    /// identifier; for the menu's checks and the chosen language's buttons.
    @State private var statuses: [String: LanguageAvailability.Status] = [:]
    /// The language `statuses` are from; they don't apply once it isn't `sourceLanguage`.
    @State private var checkedSource: String?
    /// The languages whose status in `statuses` was made sure of by translating (see
    /// `AppleTranslator.checkedStatus`); the chosen one's buttons wait for that.
    @State private var madeSure: Set<String> = []
    /// Asks macOS to download those languages each time it's set or invalidated; it shows its own
    /// dialog for that.
    @State private var download: TranslationSession.Configuration?
    /// The languages being downloaded, as `source>target`. macOS doesn't say how far along it is.
    @State private var downloading: String?
    @State private var isConfirmingDelete = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Translate recordings",
                    isOn: Bindable(preferences).translatesNotes
                )
                Group {
                    LabeledContent("Translate to") {
                        HStack {
                            Picker(
                                "Translate to",
                                selection: Bindable(preferences).translationLanguage
                            ) {
                                ForEach(choices, id: \.self) { identifier in
                                    menuTitle(for: identifier)
                                        .tag(identifier)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()

                            // macOS push buttons drop the icon unless asked to show it.
                            downloadAccessory
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    if AppleTranslator.isSameLanguage(sourceLanguage, preferences.translationLanguage) {
                        Text("Recordings in \(Self.name(of: preferences.translationLanguage)) are left as they are.")
                            .foregroundStyle(.secondary)
                    }
                    // Shown off while it can't apply, but remembered for when it can.
                    Toggle(
                        "Translate live text while recording",
                        isOn: Binding(
                            get: { preferences.translatesLiveText && environment.model.isLive },
                            set: { preferences.translatesLiveText = $0 }
                        )
                    )
                    .disabled(!environment.model.isLive)
                }
                .disabled(!preferences.translatesNotes)
            } footer: {
                Caption(footer)
            }
        }
        .formStyle(.grouped)
        .task(id: pair) {
            if languages.isEmpty {
                languages = await AppleTranslator.supportedLanguages().sorted {
                    Self.name(of: $0).localizedStandardCompare(Self.name(of: $1)) == .orderedAscending
                }
            }
            if checkedSource != sourceLanguage { await refreshStatuses() }
            // The menu's check may be wrong, so the chosen languages are made sure of each time
            // they're picked.
            await refreshStatus()
        }
        // Languages may have been downloaded or removed in System Settings meanwhile.
        .onWindowBecomesKey {
            Task {
                await refreshStatuses()
                await refreshStatus()
            }
        }
        // Off the main actor: the session isn't Sendable, so it can't be sent from there to
        // `prepareTranslation()`, which runs concurrently.
        .translationTask(download) { @concurrent session in
            let pair = await startDownload()
            // May return while macOS is still downloading, so this waits for it.
            if (try? await session.prepareTranslation()) != nil {
                await waitForDownload(pair)
            }
            await finishDownload(pair)
        }
    }

    /// The languages to pick from, with the chosen one even before macOS has listed them.
    private var choices: [String] {
        let chosen = preferences.translationLanguage
        return languages.contains(chosen) ? languages : [chosen] + languages
    }

    /// What recordings are usually in: the transcription language, or the Mac's for Automatic.
    private var sourceLanguage: String {
        preferences.language ?? Locale.current.language.minimalIdentifier
    }

    /// Which languages are shown, as `source>target`.
    private var pair: String {
        "\(sourceLanguage)>\(preferences.translationLanguage)"
    }

    /// Whether the chosen languages are downloaded; `nil` while checking.
    private var status: LanguageAvailability.Status? {
        let target = preferences.translationLanguage
        return checkedSource == sourceLanguage && madeSure.contains(target) ? statuses[target] : nil
    }

    /// The language's name, followed by a green check if it can be translated into from
    /// `sourceLanguage` without downloading anything, like the speech model menu.
    private func menuTitle(for identifier: String) -> Text {
        let name = Self.name(of: identifier)
        guard checkedSource == sourceLanguage, statuses[identifier] == .installed else { return Text(name) }
        return Text("\(name)  \(Image(nsImage: DownloadedBadge.image))")
            .accessibilityLabel("\(name), downloaded")
    }

    /// Download next to the menu while the languages aren't on this Mac, Delete once they are.
    /// Nothing for recordings already in the chosen language.
    @ViewBuilder
    private var downloadAccessory: some View {
        let source = sourceLanguage
        let target = preferences.translationLanguage
        if !AppleTranslator.isSameLanguage(source, target) {
            switch status {
            case .supported where downloading == pair:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading…")
                        .foregroundStyle(.secondary)
                }
            case .installed:
                deleteButton(from: source, to: target)
                    .labelStyle(.iconOnly)
                    .help("Delete \(Self.name(of: source)) and \(Self.name(of: target))")
            case .supported:
                Button("Download", systemImage: "arrow.down.circle") {
                    requestDownload(from: source, to: target)
                }
                .help("Download \(Self.name(of: source)) and \(Self.name(of: target)) to translate between them")
            case .unsupported:
                Text("Not supported from \(Self.name(of: source))")
                    .foregroundStyle(.secondary)
            case nil:
                ProgressView()
                    .controlSize(.small)
            @unknown default:
                EmptyView()
            }
        }
    }

    /// macOS shares translation languages with other apps and lets only System Settings remove
    /// them, so this opens it there.
    private func deleteButton(from source: String, to target: String) -> some View {
        Button("Delete", systemImage: "trash") { isConfirmingDelete = true }
            .confirmationDialog(
                "Delete \(Self.name(of: source)) and \(Self.name(of: target))?",
                isPresented: $isConfirmingDelete
            ) {
                Button("Open System Settings") { SystemSettings.open(.languageAndRegion) }
            } message: {
                Text(
                    "macOS keeps translation languages for all apps, so they're deleted in System Settings: click "
                        + "Translation Languages under Language & Region, then the trash next to each language. "
                        + "Other apps that translate, such as Translate, lose them too."
                )
            }
    }

    private func requestDownload(from source: String, to target: String) {
        let configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target)
        )
        if download?.source == configuration.source, download?.target == configuration.target {
            // The same languages again, e.g. after declining macOS's dialog; this runs it again.
            download?.invalidate()
        } else {
            download = configuration
        }
    }

    private func startDownload() -> String {
        downloading = pair
        return pair
    }

    /// Checks every second until the languages are downloaded, for up to ten minutes, or until
    /// others are picked.
    private func waitForDownload(_ pair: String) async {
        for _ in 0..<600 {
            guard pair == self.pair else { return }
            await refreshStatus()
            if status == .installed { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    private func finishDownload(_ pair: String) async {
        if downloading == pair { downloading = nil }
        await refreshStatus()
    }

    /// Checks which languages are downloaded, for the menu.
    private func refreshStatuses() async {
        let source = sourceLanguage
        let statuses = await AppleTranslator.statuses(from: source, to: choices)
        // The transcription language may have changed while macOS was asked.
        guard source == sourceLanguage, !Task.isCancelled else { return }
        // The chosen languages' status is kept until made sure of again, so their buttons don't
        // flicker: macOS may say they're installed when they aren't.
        let target = preferences.translationLanguage
        let kept = checkedSource == source && madeSure.contains(target) ? self.statuses[target] : nil
        self.statuses = statuses
        madeSure = []
        if let kept {
            self.statuses[target] = kept
            madeSure = [target]
        }
        checkedSource = source
    }

    /// Makes sure whether the chosen languages are downloaded.
    private func refreshStatus() async {
        let target = preferences.translationLanguage
        let source = sourceLanguage
        guard !AppleTranslator.isSameLanguage(source, target) else { return }
        let status = await AppleTranslator.checkedStatus(from: source, to: target)
        // The languages may have changed while macOS was asked.
        guard source == sourceLanguage, target == preferences.translationLanguage, checkedSource == source
        else { return }
        statuses[target] = status
        madeSure.insert(target)
    }

    private var footer: String {
        "Adds a translation above the transcript, and writes the summary and title in that language. "
            + "Apple's translation models do it on this Mac, with Apple Intelligence where it's on. A green "
            + "check marks the languages downloaded for recordings in \(Self.name(of: sourceLanguage)). For "
            + "recordings in other languages, download those under System Settings → General → Language "
            + "& Region → Translation Languages.\n\nWith a live model, the live text can be translated as "
            + "it's spoken too, under each line in Record and in the Dynamic Island, so you can follow a "
            + "call in a language you don't speak. Lines already in that language are left as they are."
    }

    /// "German" for `de`, "Chinese (Traditional)" for `zh-Hant`, in the user's language.
    static func name(of identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
