import MixdownAppleSpeech
import MixdownCore
import MixdownSpeechSwift

/// A speech model to transcribe with, from any of Mixdown's engines.
enum TranscriptionModel: Hashable, Identifiable {
    case speechSwift(SpeechSwiftModel)
    /// Apple's on-device speech model. macOS downloads it and keeps it up to date.
    case apple

    static var `default`: TranscriptionModel { .speechSwift(.default) }

    /// The models this Mac can use, in the order Settings lists them.
    static var available: [TranscriptionModel] {
        SpeechSwiftModel.allCases.map(Self.speechSwift) + (AppleSpeechEngine.isSupported ? [.apple] : [])
    }

    /// Persisted in user defaults; never change it. speech-swift models keep the raw values they
    /// had before there was more than one engine.
    var rawValue: String {
        switch self {
        case .speechSwift(let model): model.rawValue
        case .apple: "apple-speech"
        }
    }

    init?(rawValue: String) {
        if rawValue == Self.apple.rawValue {
            self = .apple
        } else if let model = SpeechSwiftModel(rawValue: rawValue) {
            self = .speechSwift(model)
        } else {
            return nil
        }
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speechSwift(let model): model.displayName
        case .apple: AppleSpeechEngine.displayName
        }
    }

    /// Whether `TranscriptionOptions.language` is honored. Otherwise the language is auto-detected.
    /// Apple's model doesn't detect it; it falls back to the Mac's language.
    var supportsLanguageSelection: Bool {
        switch self {
        case .speechSwift(let model): model.supportsLanguageSelection
        case .apple: true
        }
    }

    /// Whether transcript segments carry speaker labels.
    var labelsSpeakers: Bool {
        switch self {
        case .speechSwift(let model): model.labelsSpeakers
        case .apple: false
        }
    }

    /// Whether the model is on disk, if that can be told right away. `nil` for Apple's model, which
    /// macOS only reports asynchronously (see `AppleSpeechEngine.isInstalled(language:)`).
    var isDownloaded: Bool? {
        switch self {
        case .speechSwift(let model): SpeechSwiftEngine.isDownloaded(model)
        case .apple: nil
        }
    }

    /// Whether macOS stores the model rather than Mixdown, so Mixdown can't delete it.
    var isManagedBySystem: Bool {
        switch self {
        case .speechSwift: false
        case .apple: true
        }
    }

    func makeEngine() -> any TranscriptionEngine {
        switch self {
        case .speechSwift(let model): SpeechSwiftEngine(model: model)
        case .apple: AppleSpeechEngine()
        }
    }
}
