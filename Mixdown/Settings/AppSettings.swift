import Foundation
import MixdownCore
import MixdownSpeechSwift

/// Typed access to Mixdown's preferences in `UserDefaults`.
///
/// The `Key` constants are the single source of truth for key names and can be used directly
/// with `@AppStorage`.
struct AppSettings {
    enum Key {
        /// Single-input selection from before multi-source recording; read once to migrate.
        static let legacySelectedDeviceID = "selectedDeviceID"
        static let selectedDeviceIDs = "selectedDeviceIDs"
        static let microphoneLabel = "microphoneSpeakerLabel"
        static let systemAudioLabel = "systemAudioSpeakerLabel"
        static let transcriptionModel = "transcriptionModel"
        static let notesFolderBookmark = "notesFolderBookmark"
        /// ISO 639-1 code; absent means auto-detect.
        static let language = "transcriptionLanguage"
        /// Whether to move notes to the Trash without asking first. Read with `@AppStorage`.
        static let suppressesTrashConfirmation = "suppressesTrashConfirmation"
        static let callRecording = "callRecording"
    }

    var defaults: UserDefaults = .standard

    /// The inputs the user picked last. Kept even while a device is unplugged so it is
    /// re-selected when it comes back.
    var selectedDeviceIDs: [String] {
        get {
            defaults.stringArray(forKey: Key.selectedDeviceIDs)
                ?? defaults.string(forKey: Key.legacySelectedDeviceID).map { [$0] }
                ?? []
        }
        nonmutating set {
            defaults.set(newValue, forKey: Key.selectedDeviceIDs)
            defaults.removeObject(forKey: Key.legacySelectedDeviceID)
        }
    }

    /// Speaker names for recordings with more than one input. Blank values fall back to the
    /// defaults when the transcript is labeled.
    var sourceLabels: SourceLabels {
        get {
            SourceLabels(
                microphone: defaults.string(forKey: Key.microphoneLabel) ?? SourceLabels.defaultMicrophone,
                systemAudio: defaults.string(forKey: Key.systemAudioLabel) ?? SourceLabels.defaultSystemAudio
            )
        }
        nonmutating set {
            defaults.set(newValue.microphone, forKey: Key.microphoneLabel)
            defaults.set(newValue.systemAudio, forKey: Key.systemAudioLabel)
        }
    }

    var transcriptionModel: SpeechSwiftModel {
        get { defaults.string(forKey: Key.transcriptionModel).flatMap(SpeechSwiftModel.init(rawValue:)) ?? .default }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.transcriptionModel) }
    }

    /// Security-scoped bookmark to the notes folder the user chose. `nil` until they choose one.
    var notesFolderBookmark: Data? {
        get { defaults.data(forKey: Key.notesFolderBookmark) }
        nonmutating set { defaults.set(newValue, forKey: Key.notesFolderBookmark) }
    }

    /// `nil` means auto-detect.
    var language: String? {
        get { defaults.string(forKey: Key.language) }
        nonmutating set { defaults.set(newValue, forKey: Key.language) }
    }

    /// What to do when a call app starts using a microphone. Asks unless changed.
    var callRecording: CallRecording {
        get { defaults.string(forKey: Key.callRecording).flatMap(CallRecording.init(rawValue:)) ?? .ask }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.callRecording) }
    }
}

/// What Mixdown does when a call starts and ends. See `CallPrompt`.
enum CallRecording: String, CaseIterable, Identifiable {
    /// Calls aren't watched.
    case off
    /// A notification offers to record when a call starts, and to stop when it ends.
    case ask
    /// Recording starts and stops with the call, and a notification says so.
    case automatic

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Do Nothing"
        case .ask: "Ask to Record"
        case .automatic: "Record Automatically"
        }
    }
}
