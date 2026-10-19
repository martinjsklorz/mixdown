import Foundation

/// Identifies a translator for UI.
public struct TranslatorInfo: Sendable, Equatable {
    /// Stable identifier, e.g. `"apple-translation"`.
    public let id: String
    /// Human-readable name, e.g. `"Apple Translation"`.
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// The seam between Mixdown and a translation backend.
///
/// Implementations must run entirely on-device. The rest of the app only ever talks to this
/// protocol, so offering another backend means adding a new conforming type and constructing it
/// where the translator is chosen.
public protocol Translator: Sendable {
    var info: TranslatorInfo { get }

    /// Translates the text of each segment into `target`, keeping its times and speaker, and sets
    /// the result's `language` to `target`. Translates from `transcript.language`, or the language
    /// the text is in if that's `nil`. Returns `nil` if the transcript is in `target` already.
    /// Honors task cancellation.
    /// - Parameter target: A BCP 47 language identifier, e.g. `"de"` or `"zh-Hant"`.
    func translate(_ transcript: Transcript, to target: String) async throws -> Transcript?
}

/// Named for transcripts so it doesn't clash with the Translation framework's `TranslationError`
/// in modules that import both.
public enum TranscriptTranslationError: LocalizedError, Sendable, Equatable {
    /// The languages are supported but not on this Mac yet. BCP 47 identifiers.
    case notInstalled(source: String, target: String)
    /// The backend can't translate between these languages. BCP 47 identifiers.
    case unsupported(source: String, target: String)
    /// The transcript didn't say what language it's in, and it couldn't be told from the text.
    case unknownSourceLanguage
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let source, let target):
            "Translating from \(Self.name(of: source)) to \(Self.name(of: target)) needs those languages "
                + "downloaded first, under Settings → Transcription → Translation."
        case .unsupported(let source, let target):
            "Translating from \(Self.name(of: source)) to \(Self.name(of: target)) isn't supported."
        case .unknownSourceLanguage:
            "The language of the recording couldn't be told, so it wasn't translated. Choose the "
                + "language under Settings → Transcription."
        case .failed(let reason):
            "Translating failed: \(reason)"
        }
    }

    /// "German" for `"de"`, in the user's language.
    static func name(of identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
