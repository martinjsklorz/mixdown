import Foundation
import MixdownSpeechSwift

/// Typed access to Mixdown's preferences in `UserDefaults`.
///
/// The `Key` constants are the single source of truth for key names and can be used directly
/// with `@AppStorage`.
struct AppSettings {
    enum Key {
        static let selectedDeviceID = "selectedDeviceID"
        static let transcriptionModel = "transcriptionModel"
        static let notesFolderBookmark = "notesFolderBookmark"
        /// ISO 639-1 code; absent means auto-detect.
        static let language = "transcriptionLanguage"
    }

    var defaults: UserDefaults = .standard

    /// The input the user picked last. Kept even while that device is unplugged so it is
    /// re-selected when it comes back.
    var selectedDeviceID: String? {
        get { defaults.string(forKey: Key.selectedDeviceID) }
        nonmutating set { defaults.set(newValue, forKey: Key.selectedDeviceID) }
    }

    var transcriptionModel: SpeechSwiftModel {
        get { defaults.string(forKey: Key.transcriptionModel).flatMap(SpeechSwiftModel.init(rawValue:)) ?? .default }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.transcriptionModel) }
    }

    /// Security-scoped bookmark to a user-chosen notes folder. `nil` means the default folder.
    var notesFolderBookmark: Data? {
        get { defaults.data(forKey: Key.notesFolderBookmark) }
        nonmutating set { defaults.set(newValue, forKey: Key.notesFolderBookmark) }
    }

    /// `nil` means auto-detect.
    var language: String? {
        get { defaults.string(forKey: Key.language) }
        nonmutating set { defaults.set(newValue, forKey: Key.language) }
    }
}
