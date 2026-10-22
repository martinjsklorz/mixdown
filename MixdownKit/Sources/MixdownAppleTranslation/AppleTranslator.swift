import Foundation
import MixdownCore
import MixdownNaturalLanguage
import Translation

/// Translates with Apple's on-device translation models, through the Translation framework: the
/// ones the Translate app uses. macOS downloads them once per language and shares them with other
/// apps; nothing leaves the Mac.
///
/// On macOS 26.4 and later it asks for Apple Intelligence's more fluent translations, which macOS
/// falls back from to the classic models where Apple Intelligence is off or lacks the languages.
/// Whether a language is ready is still judged by the classic models, which that fallback needs.
///
/// Languages must be downloaded before translating, which only a SwiftUI `translationTask` can
/// ask for (see Settings); `translate` throws `TranscriptTranslationError.notInstalled` until then.
public struct AppleTranslator: Translator {
    public let info = TranslatorInfo(id: "apple-translation", displayName: "Apple Translation")

    /// Segments handed to the framework at once, so a long recording is checked for cancellation
    /// between batches.
    private static let batchSize = 50

    public init() {}

    public func translate(
        _ transcript: MixdownCore.Transcript,
        to target: String
    ) async throws -> MixdownCore.Transcript? {
        let targetLanguage = Locale.Language(identifier: target)
        guard let source = TranscriptLanguage.code(of: transcript).map(Locale.Language.init(identifier:)) else {
            throw TranscriptTranslationError.unknownSourceLanguage
        }
        guard !Self.isSameLanguage(source, targetLanguage) else { return nil }

        switch await Self.status(from: source, to: targetLanguage) {
        case .installed:
            break
        case .supported:
            throw TranscriptTranslationError.notInstalled(source: source.minimalIdentifier, target: target)
        case .unsupported:
            throw TranscriptTranslationError.unsupported(source: source.minimalIdentifier, target: target)
        @unknown default:
            break
        }

        let session = Self.makeSession(from: source, to: targetLanguage)
        let requests = transcript.segments.indices.compactMap { index -> TranslationSession.Request? in
            let text = transcript.segments[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }
        var segments = transcript.segments
        for start in stride(from: 0, to: requests.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let batch = Array(requests[start..<min(start + Self.batchSize, requests.count)])
            let responses: [TranslationSession.Response]
            do {
                responses = try await session.translations(from: batch)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw TranscriptTranslationError.failed(error.localizedDescription)
            }
            for response in responses {
                guard let index = response.clientIdentifier.flatMap(Int.init), segments.indices.contains(index)
                else { continue }
                segments[index].text = response.targetText
            }
        }
        return MixdownCore.Transcript(segments: segments, language: target)
    }

    // MARK: - Languages

    /// The languages the framework translates between, as BCP 47 identifiers, e.g. `"de"` or
    /// `"zh-Hant"`. Not all of them may be downloaded yet.
    public static func supportedLanguages() async -> [String] {
        var seen = Set<String>()
        return await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier).filter {
            seen.insert($0).inserted
        }
    }

    /// Whether translating from `source` to `target` (BCP 47 identifiers) is possible, and whether
    /// its languages are downloaded.
    public static func status(from source: String, to target: String) async -> LanguageAvailability.Status {
        await status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
    }

    /// Whether two identifiers name the same language and script, e.g. `en-US` and `en-GB`, so
    /// there's nothing to translate. `zh-Hans` and `zh-Hant` differ.
    public static func isSameLanguage(_ first: String, _ second: String) -> Bool {
        isSameLanguage(Locale.Language(identifier: first), Locale.Language(identifier: second))
    }

    private static func isSameLanguage(_ first: Locale.Language, _ second: Locale.Language) -> Bool {
        // Maximized, so `zh` gets the script it's written in by default.
        let first = Locale.Language(identifier: first.maximalIdentifier)
        let second = Locale.Language(identifier: second.maximalIdentifier)
        return first.languageCode == second.languageCode && first.script == second.script
    }

    private static func status(
        from source: Locale.Language,
        to target: Locale.Language
    ) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: target)
    }

    // MARK: - Session

    private static func makeSession(from source: Locale.Language, to target: Locale.Language) -> TranslationSession {
        if #available(macOS 26.4, *) {
            TranslationSession(installedSource: source, target: target, preferredStrategy: .highFidelity)
        } else {
            TranslationSession(installedSource: source, target: target)
        }
    }
}
