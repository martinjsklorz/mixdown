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
        /// Whether Mixdown posts notifications at all. Absent means yes.
        static let showsNotifications = "showsNotifications"
        /// Whether the global recording shortcut is on. Absent means yes. The shortcut itself is
        /// stored by KeyboardShortcuts.
        static let recordingShortcutEnabled = "recordingShortcutEnabled"
        /// Whether notes get a summary. Absent means yes.
        static let summarizesNotes = "summarizesNotes"
        /// A `SummaryTemplate` raw value for recordings started by hand. Absent means `.general`.
        static let summaryTemplate = "summaryTemplate"
        /// A `SummaryTemplate` raw value for recordings started for a call. Absent means `.general`.
        static let callSummaryTemplate = "callSummaryTemplate"
        /// Whether Mixdown plays audio cues at all. Absent means yes.
        static let playsSounds = "playsSounds"
        /// Whether to post notifications when calls start and end. Absent means yes.
        static let notifiesAboutCalls = "notifiesAboutCalls"
        /// Whether to start and stop recording with calls. Absent means no.
        static let recordsCallsAutomatically = "recordsCallsAutomatically"
        /// An `Appearance` raw value. Absent means `.auto`. Read with `@AppStorage`.
        static let appearance = "appearance"
        /// Whether a recording's time and input levels show around the notch instead of in the
        /// menu bar. Absent means yes.
        static let showsRecordingInNotch = "showsRecordingInNotch"
        /// A `NotchIsland.Side` raw value for the recording time. Absent means left.
        static let islandTimeSide = "islandTimeSide"
        /// Whether the notch island shows the input levels. Absent means yes.
        static let islandShowsLevels = "islandShowsLevels"
        /// Whether to show the setup assistant at launch. Absent means yes, unless a notes folder
        /// was chosen before the assistant existed.
        static let needsSetup = "needsSetup"

        /// The name of the sound played for `cue`; empty for none. Absent means the cue's default.
        static func sound(for cue: AudioCue) -> String { "sound.\(cue.rawValue)" }
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

    var showsNotifications: Bool {
        get { defaults.object(forKey: Key.showsNotifications) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.showsNotifications) }
    }

    var isRecordingShortcutEnabled: Bool {
        get { defaults.object(forKey: Key.recordingShortcutEnabled) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.recordingShortcutEnabled) }
    }

    var summarizesNotes: Bool {
        get { defaults.object(forKey: Key.summarizesNotes) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.summarizesNotes) }
    }

    var summaryTemplate: SummaryTemplate {
        get { defaults.string(forKey: Key.summaryTemplate).flatMap(SummaryTemplate.init(rawValue:)) ?? .general }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.summaryTemplate) }
    }

    var callSummaryTemplate: SummaryTemplate {
        get { defaults.string(forKey: Key.callSummaryTemplate).flatMap(SummaryTemplate.init(rawValue:)) ?? .general }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.callSummaryTemplate) }
    }

    var playsSounds: Bool {
        get { defaults.object(forKey: Key.playsSounds) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.playsSounds) }
    }

    /// The name of the sound for `cue`, or `nil` if the user chose none.
    func sound(for cue: AudioCue) -> String? {
        let name = defaults.string(forKey: Key.sound(for: cue)) ?? cue.defaultSound
        return name.isEmpty ? nil : name
    }

    /// `nil` means auto-detect.
    var language: String? {
        get { defaults.string(forKey: Key.language) }
        nonmutating set { defaults.set(newValue, forKey: Key.language) }
    }

    /// Whether to post notifications when calls start and end. On unless turned off.
    var notifiesAboutCalls: Bool {
        get { defaults.object(forKey: Key.notifiesAboutCalls) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.notifiesAboutCalls) }
    }

    /// Whether to start and stop recording with calls, without asking. Off unless turned on.
    var recordsCallsAutomatically: Bool {
        get { defaults.bool(forKey: Key.recordsCallsAutomatically) }
        nonmutating set { defaults.set(newValue, forKey: Key.recordsCallsAutomatically) }
    }

    /// Light or dark mode for the app. Follows the system unless set.
    var appearance: Appearance {
        defaults.string(forKey: Key.appearance).flatMap(Appearance.init(rawValue:)) ?? .auto
    }

    /// Whether to show a recording around the notch. On unless turned off.
    var showsRecordingInNotch: Bool {
        get { defaults.object(forKey: Key.showsRecordingInNotch) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.showsRecordingInNotch) }
    }

    /// Whether the setup assistant opens at launch. Until it's finished or put off, and on first
    /// run; not for those who chose a notes folder in a version without it.
    var needsSetup: Bool {
        get { defaults.object(forKey: Key.needsSetup) as? Bool ?? (notesFolderBookmark == nil) }
        nonmutating set { defaults.set(newValue, forKey: Key.needsSetup) }
    }

    /// What the notch island shows, and where.
    var islandLayout: NotchIsland.Layout {
        get {
            NotchIsland.Layout(
                timeSide: defaults.string(forKey: Key.islandTimeSide).flatMap(NotchIsland.Side.init(rawValue:))
                    ?? .left,
                showsLevels: defaults.object(forKey: Key.islandShowsLevels) as? Bool ?? true
            )
        }
        nonmutating set {
            defaults.set(newValue.timeSide.rawValue, forKey: Key.islandTimeSide)
            defaults.set(newValue.showsLevels, forKey: Key.islandShowsLevels)
        }
    }
}

