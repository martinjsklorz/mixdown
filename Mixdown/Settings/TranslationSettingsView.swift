import MixdownAppleTranslation
import SwiftUI
import Translation

/// Whether notes are translated, which language into, and whether macOS has the languages to
/// translate the usual recordings.
struct TranslationSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    /// BCP 47 identifiers of the languages Apple's models translate between, by name. Empty until
    /// macOS has said.
    @State private var languages: [String] = []
    /// Whether the languages from `sourceLanguage` to the target are downloaded; `nil` while
    /// checking.
    @State private var status: LanguageAvailability.Status?
    /// Asks macOS to download those languages each time it's set or invalidated; it shows its own
    /// dialog for that.
    @State private var download: TranslationSession.Configuration?
    /// The languages being downloaded, as `source>target`. macOS doesn't say how far along it is.
    @State private var downloading: String?

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Translate recordings",
                    isOn: Binding(
                        get: { environment.translatesNotes },
                        set: { environment.translatesNotes = $0 }
                    )
                )
                Group {
                    Picker(
                        "Translate to",
                        selection: Binding(
                            get: { environment.translationLanguage },
                            set: { environment.setTranslationLanguage($0) }
                        )
                    ) {
                        ForEach(choices, id: \.self) { identifier in
                            Text(Self.name(of: identifier)).tag(identifier)
                        }
                    }
                    languagePairRow(to: environment.translationLanguage)
                    // Shown off while it can't apply, but remembered for when it can.
                    Toggle(
                        "Translate live text while recording",
                        isOn: Binding(
                            get: { environment.translatesLiveText && environment.model.isLive },
                            set: { environment.translatesLiveText = $0 }
                        )
                    )
                    .disabled(!environment.model.isLive)
                }
                .disabled(!environment.translatesNotes)
            } footer: {
                Caption(footer)
            }
        }
        .formStyle(.grouped)
        .task {
            languages = await AppleTranslator.supportedLanguages().sorted {
                Self.name(of: $0).localizedStandardCompare(Self.name(of: $1)) == .orderedAscending
            }
        }
        .task(id: pair) {
            // Not the previous languages' status while checking.
            status = nil
            await refreshStatus()
        }
        // Languages may have been downloaded in System Settings meanwhile.
        .onWindowBecomesKey { Task { await refreshStatus() } }
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
        let chosen = environment.translationLanguage
        return languages.contains(chosen) ? languages : [chosen] + languages
    }

    /// What recordings are usually in: the transcription language, or the Mac's for Automatic.
    private var sourceLanguage: String {
        environment.language ?? Locale.current.language.minimalIdentifier
    }

    /// Which languages are shown, as `source>target`.
    private var pair: String {
        "\(sourceLanguage)>\(environment.translationLanguage)"
    }

    /// "English → German", and whether those are downloaded, with a button to download them.
    @ViewBuilder
    private func languagePairRow(to target: String) -> some View {
        let source = sourceLanguage
        if AppleTranslator.isSameLanguage(source, target) {
            Text("Recordings in \(Self.name(of: target)) are left as they are.")
                .foregroundStyle(.secondary)
        } else {
            LabeledContent("\(Self.name(of: source)) → \(Self.name(of: target))") {
                switch status {
                case .supported where downloading == pair:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Downloading…")
                            .foregroundStyle(.secondary)
                    }
                case .installed:
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                        .symbolRenderingMode(.multicolor)
                        .labelStyle(.titleAndIcon)
                case .supported:
                    Button("Download", systemImage: "arrow.down.circle") {
                        requestDownload(from: source, to: target)
                    }
                    .labelStyle(.titleAndIcon)
                case .unsupported:
                    Text("Not supported")
                        .foregroundStyle(.secondary)
                case nil:
                    ProgressView()
                        .controlSize(.small)
                @unknown default:
                    EmptyView()
                }
            }
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

    private func refreshStatus() async {
        let target = environment.translationLanguage
        let source = sourceLanguage
        let status = await AppleTranslator.status(from: source, to: target)
        // The languages may have changed while macOS was asked.
        guard source == sourceLanguage, target == environment.translationLanguage else { return }
        self.status = status
    }

    private var footer: String {
        "Adds a translation above the transcript, and writes the summary and title in that language. "
            + "Apple's translation models do it on this Mac, with Apple Intelligence where it's on. For "
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
