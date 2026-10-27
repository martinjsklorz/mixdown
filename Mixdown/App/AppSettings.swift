import Foundation
import MixdownCore

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
        /// Whether notes are added to Spotlight. Absent means yes.
        static let indexesNotesInSpotlight = "indexesNotesInSpotlight"
        /// Whether Chat is offered. Absent means yes.
        static let chatEnabled = "chatEnabled"
        /// Whether the sidebar's pinned notes are folded away. Absent means no. Read with
        /// `@AppStorage`.
        static let collapsesPinnedNotes = "collapsesPinnedNotes"
        /// Whether the global recording shortcut is on. Absent means yes. The shortcut itself is
        /// stored by KeyboardShortcuts.
        static let recordingShortcutEnabled = "recordingShortcutEnabled"
        /// How many of the last minutes of a recording Catch Me Up sums up. Absent means 5.
        static let catchUpMinutes = "catchUpMinutes"
        /// Whether notes get a summary. Absent means yes.
        static let summarizesNotes = "summarizesNotes"
        /// A `SummaryModel` raw value. Absent means `.appleIntelligence`.
        static let summaryModel = "summaryModel"
        /// A `SummaryTemplate` id for recordings started by hand. Absent means `general`.
        static let summaryTemplate = "summaryTemplate"
        /// A `SummaryTemplate` id for recordings started for a call. Absent means `general`.
        static let callSummaryTemplate = "callSummaryTemplate"
        /// The user's own `SummaryTemplate`s and the built-ins they edited, as JSON. Absent means
        /// just the built-ins as they came.
        static let summaryTemplates = "summaryTemplates"
        /// Whether notes are translated. Absent means yes if a `translationLanguage` was picked
        /// before this setting existed, else no.
        static let translatesNotes = "translatesNotes"
        /// BCP 47 identifier of the language notes are translated into. Absent means the Mac's.
        static let translationLanguage = "translationLanguage"
        /// Whether the live text is translated into that language while recording, too. Absent
        /// means yes.
        static let translatesLiveText = "translatesLiveText"
        /// A `Vocabulary` as JSON. Absent means no words.
        static let vocabulary = "vocabulary"
        /// Whether Mixdown plays audio cues at all. Absent means yes.
        static let playsSounds = "playsSounds"
        /// Whether to post notifications when calls start and end. Absent means yes.
        static let notifiesAboutCalls = "notifiesAboutCalls"
        /// Whether to start and stop recording with calls. Absent means no.
        static let recordsCallsAutomatically = "recordsCallsAutomatically"
        /// A `CallAppSelection` as JSON. Absent means every known call app and browser.
        static let callApps = "callApps"
        /// Minutes without speech before Mixdown asks whether it's still recording; 0 for never.
        /// Absent means 15.
        static let stillRecordingMinutes = "stillRecordingMinutes"
        /// Whether to take the system audio's echo out of the microphone. Absent means yes.
        static let cancelsEcho = "cancelsEcho"
        /// Whether to time how long the user and the others talk while both a microphone and
        /// system audio record. Absent means no.
        static let measuresTalkTime = "measuresTalkTime"
        /// Whether recordings' audio is written to disk until their notes are saved. Absent means
        /// yes.
        static let keepsAudioOnDisk = "keepsAudioOnDisk"
        /// Whether the people on the system audio are told apart once a recording ends. Absent
        /// means no.
        static let identifiesSpeakers = "identifiesSpeakers"
        /// Whether the speakers told apart are named after what's said. Absent means yes.
        static let namesSpeakers = "namesSpeakers"
        /// An `Appearance` raw value. Absent means `.auto`. Read with `@AppStorage`.
        static let appearance = "appearance"
        /// Whether a recording's time and input levels show in the Dynamic Island instead of in the
        /// menu bar. Absent means yes. Still named for the notch, so the setting carries over.
        static let showsRecordingInDynamicIsland = "showsRecordingInNotch"
        /// A `DynamicIsland.Side` raw value for the recording time. Absent means left.
        static let islandTimeSide = "islandTimeSide"
        /// Whether the Dynamic Island shows the input levels. Absent means yes.
        static let islandShowsLevels = "islandShowsLevels"
        /// Whether the Dynamic Island shows the latest words under the notch while a live model
        /// transcribes. Absent means no.
        static let islandShowsLiveText = "islandShowsLiveText"
        /// Whether the Dynamic Island shows how the talking is shared while recording both a
        /// microphone and system audio. Absent means yes.
        static let islandShowsTalkShare = "islandShowsTalkShare"
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

    /// The chosen model, or the default if it's not available on this Mac (any more).
    var transcriptionModel: TranscriptionModel {
        get {
            let model = defaults.string(forKey: Key.transcriptionModel).flatMap(TranscriptionModel.init(rawValue:))
            return model.flatMap { TranscriptionModel.available.contains($0) ? $0 : nil } ?? .default
        }
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

    var indexesNotesInSpotlight: Bool {
        get { defaults.object(forKey: Key.indexesNotesInSpotlight) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.indexesNotesInSpotlight) }
    }

    var isChatEnabled: Bool {
        get { defaults.object(forKey: Key.chatEnabled) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.chatEnabled) }
    }

    var isRecordingShortcutEnabled: Bool {
        get { defaults.object(forKey: Key.recordingShortcutEnabled) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.recordingShortcutEnabled) }
    }

    /// One of `catchUpMinuteChoices`.
    var catchUpMinutes: Int {
        get {
            let minutes = defaults.integer(forKey: Key.catchUpMinutes)
            return Self.catchUpMinuteChoices.contains(minutes) ? minutes : 5
        }
        nonmutating set { defaults.set(newValue, forKey: Key.catchUpMinutes) }
    }

    /// What Settings offers for `catchUpMinutes`. About ten minutes of talking fill the on-device
    /// model's context, so more is caught up on in parts, which takes longer.
    static let catchUpMinuteChoices = [1, 2, 5, 10, 15]

    var summarizesNotes: Bool {
        get { defaults.object(forKey: Key.summarizesNotes) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.summarizesNotes) }
    }

    var summaryModel: SummaryModel {
        get { defaults.string(forKey: Key.summaryModel).flatMap(SummaryModel.init(rawValue:)) ?? .default }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.summaryModel) }
    }

    /// Every template on offer and those recordings use. Only what differs from the built-ins as
    /// they came is stored.
    var summaryTemplates: SummaryTemplateLibrary {
        get {
            let stored =
                defaults.data(forKey: Key.summaryTemplates).flatMap {
                    try? JSONDecoder().decode([SummaryTemplate].self, from: $0)
                } ?? []
            return SummaryTemplateLibrary(
                stored: stored,
                recordingTemplateID: defaults.string(forKey: Key.summaryTemplate),
                callTemplateID: defaults.string(forKey: Key.callSummaryTemplate)
            )
        }
        nonmutating set {
            defaults.set(try? JSONEncoder().encode(newValue.changedTemplates), forKey: Key.summaryTemplates)
            defaults.set(newValue.recordingTemplateID, forKey: Key.summaryTemplate)
            defaults.set(newValue.callTemplateID, forKey: Key.callSummaryTemplate)
        }
    }

    var cancelsEcho: Bool {
        get { defaults.object(forKey: Key.cancelsEcho) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.cancelsEcho) }
    }

    var measuresTalkTime: Bool {
        get { defaults.bool(forKey: Key.measuresTalkTime) }
        nonmutating set { defaults.set(newValue, forKey: Key.measuresTalkTime) }
    }

    var keepsAudioOnDisk: Bool {
        get { defaults.object(forKey: Key.keepsAudioOnDisk) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.keepsAudioOnDisk) }
    }

    var identifiesSpeakers: Bool {
        get { defaults.bool(forKey: Key.identifiesSpeakers) }
        nonmutating set { defaults.set(newValue, forKey: Key.identifiesSpeakers) }
    }

    var namesSpeakers: Bool {
        get { defaults.object(forKey: Key.namesSpeakers) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.namesSpeakers) }
    }

    /// One of `stillRecordingMinuteChoices`, or 0 to never ask.
    var stillRecordingMinutes: Int {
        get {
            guard let minutes = defaults.object(forKey: Key.stillRecordingMinutes) as? Int else { return 15 }
            return minutes == 0 || Self.stillRecordingMinuteChoices.contains(minutes) ? minutes : 15
        }
        nonmutating set { defaults.set(newValue, forKey: Key.stillRecordingMinutes) }
    }

    /// What Settings offers for `stillRecordingMinutes`, besides never.
    static let stillRecordingMinuteChoices = [5, 10, 15, 30, 60]

    var playsSounds: Bool {
        get { defaults.object(forKey: Key.playsSounds) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.playsSounds) }
    }

    /// The name of the sound for `cue`, or `nil` if the user chose none.
    func sound(for cue: AudioCue) -> String? {
        let name = defaults.string(forKey: Key.sound(for: cue)) ?? cue.defaultSound
        return name.isEmpty ? nil : name
    }

    var translatesNotes: Bool {
        get {
            defaults.object(forKey: Key.translatesNotes) as? Bool
                ?? (defaults.string(forKey: Key.translationLanguage) != nil)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.translatesNotes) }
    }

    /// Kept while `translatesNotes` is off.
    var translationLanguage: String {
        get { defaults.string(forKey: Key.translationLanguage) ?? Locale.current.language.minimalIdentifier }
        nonmutating set { defaults.set(newValue, forKey: Key.translationLanguage) }
    }

    var translatesLiveText: Bool {
        get { defaults.object(forKey: Key.translatesLiveText) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.translatesLiveText) }
    }

    /// Words to correct in transcripts. Empty if none were added, or what's stored can't be read.
    var vocabulary: Vocabulary {
        get {
            defaults.data(forKey: Key.vocabulary).flatMap { try? JSONDecoder().decode(Vocabulary.self, from: $0) }
                ?? Vocabulary()
        }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.vocabulary) }
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

    /// Which apps count as calls. Every known one unless changed.
    var callApps: CallAppSelection {
        get {
            defaults.data(forKey: Key.callApps).flatMap { try? JSONDecoder().decode(CallAppSelection.self, from: $0) }
                ?? CallAppSelection()
        }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.callApps) }
    }

    /// Light or dark mode for the app. Follows the system unless set.
    var appearance: Appearance {
        defaults.string(forKey: Key.appearance).flatMap(Appearance.init(rawValue:)) ?? .auto
    }

    /// Whether to show a recording in the Dynamic Island. On unless turned off.
    var showsRecordingInDynamicIsland: Bool {
        get { defaults.object(forKey: Key.showsRecordingInDynamicIsland) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.showsRecordingInDynamicIsland) }
    }

    /// Whether the setup assistant opens at launch. Until it's finished or put off, and on first
    /// run; not for those who chose a notes folder in a version without it.
    var needsSetup: Bool {
        get { defaults.object(forKey: Key.needsSetup) as? Bool ?? (notesFolderBookmark == nil) }
        nonmutating set { defaults.set(newValue, forKey: Key.needsSetup) }
    }

    /// What the Dynamic Island shows, and where.
    var islandLayout: DynamicIsland.Layout {
        get {
            DynamicIsland.Layout(
                timeSide: defaults.string(forKey: Key.islandTimeSide).flatMap(DynamicIsland.Side.init(rawValue:))
                    ?? .left,
                showsLevels: defaults.object(forKey: Key.islandShowsLevels) as? Bool ?? true,
                showsLiveText: defaults.bool(forKey: Key.islandShowsLiveText),
                showsTalkShare: defaults.object(forKey: Key.islandShowsTalkShare) as? Bool ?? true
            )
        }
        nonmutating set {
            defaults.set(newValue.timeSide.rawValue, forKey: Key.islandTimeSide)
            defaults.set(newValue.showsLevels, forKey: Key.islandShowsLevels)
            defaults.set(newValue.showsLiveText, forKey: Key.islandShowsLiveText)
            defaults.set(newValue.showsTalkShare, forKey: Key.islandShowsTalkShare)
        }
    }
}
