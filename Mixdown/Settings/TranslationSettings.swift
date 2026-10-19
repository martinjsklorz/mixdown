import AppKit
import MixdownAppleTranslation
import SwiftUI
import Translation

/// The Translation section of Settings → Transcription: which language notes are translated into,
/// and whether macOS has the languages to translate the usual recordings.
struct TranslationSettings: View {
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

    var body: some View {
        Section {
            Picker(
                "Translate to",
                selection: Binding(
                    get: { environment.translationLanguage },
                    set: { environment.translationLanguage = $0 }
                )
            ) {
                Text("Off").tag(String?.none)
                Divider()
                ForEach(choices, id: \.self) { identifier in
                    Text(Self.name(of: identifier)).tag(Optional(identifier))
                }
            }

            if let target = environment.translationLanguage {
                languagePairRow(to: target)
            }
        } header: {
            Text("Translation")
        } footer: {
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            languages = await AppleTranslator.supportedLanguages().sorted {
                Self.name(of: $0).localizedStandardCompare(Self.name(of: $1)) == .orderedAscending
            }
        }
        .task(id: "\(sourceLanguage)>\(environment.translationLanguage ?? "")") {
            // Not the previous languages' status while checking.
            status = nil
            await refreshStatus()
        }
        // Languages may have been downloaded in System Settings meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await refreshStatus() }
        }
        .translationTask(download) { session in
            try? await session.prepareTranslation()
            await refreshStatus()
        }
    }

    /// The languages to pick from, with the chosen one even before macOS has listed them.
    private var choices: [String] {
        guard let chosen = environment.translationLanguage, !languages.contains(chosen) else { return languages }
        return [chosen] + languages
    }

    /// What recordings are usually in: the transcription language, or the Mac's for Automatic.
    private var sourceLanguage: String {
        environment.language ?? Locale.current.language.minimalIdentifier
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

    private func refreshStatus() async {
        guard let target = environment.translationLanguage else { return }
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
            + "& Region → Translation Languages."
    }

    /// "German" for `de`, "Chinese (Traditional)" for `zh-Hant`, in the user's language.
    static func name(of identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
