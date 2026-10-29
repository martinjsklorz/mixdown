import Foundation
import MixdownCore
import Observation

/// The preferences Mixdown acts on while it runs, for views to show and change. Each is stored in
/// `AppSettings` as it's set, then `didChange` is called, with which `AppEnvironment` hands them to
/// the coordinator and the other parts that use them, from one place.
///
/// The transcription and summary models aren't here, as changing them replaces parts; see
/// `AppEnvironment.setModel(_:)` and `AppEnvironment.setSummaryModel(_:)`.
@MainActor @Observable
final class Preferences {
    // MARK: Recording

    /// Whether to take the system audio's echo out of the microphone. Takes effect from the next
    /// recording.
    var cancelsEcho: Bool { didSet { save { $0.cancelsEcho = cancelsEcho } } }
    /// Whether to time how long the user and the others talk while both a microphone and system
    /// audio record. Takes effect from the next recording.
    var measuresTalkTime: Bool { didSet { save { $0.measuresTalkTime = measuresTalkTime } } }
    /// Whether recordings' audio is written to disk until their notes are saved, so quitting or a
    /// crash doesn't lose them; otherwise it's only kept in memory. Takes effect from the next
    /// recording.
    var keepsAudioOnDisk: Bool { didSet { save { $0.keepsAudioOnDisk = keepsAudioOnDisk } } }
    /// Minutes without speech before Mixdown asks whether it's still recording; 0 for never. Takes
    /// effect right away, even while recording. See `StillRecordingPrompt`.
    var stillRecordingMinutes: Int { didSet { save { $0.stillRecordingMinutes = stillRecordingMinutes } } }
    /// Whether the global shortcut (`KeyboardShortcuts.Name.toggleRecording`) starts and stops
    /// recording. Off, the shortcut is kept but released, so other apps get those keys.
    var isRecordingShortcutEnabled: Bool {
        didSet { save { $0.isRecordingShortcutEnabled = isRecordingShortcutEnabled } }
    }
    /// How many of the last minutes of a recording Catch Me Up sums up.
    var catchUpMinutes: Int { didSet { save { $0.catchUpMinutes = catchUpMinutes } } }

    // MARK: Notifications

    /// Whether Mixdown posts notifications at all. Off, it doesn't notify about calls either. See
    /// `Notifications`.
    var showsNotifications: Bool { didSet { save { $0.showsNotifications = showsNotifications } } }
    /// Whether recording starting, pausing, stopping and finishing plays a sound. See `AudioCues`.
    var playsSounds: Bool { didSet { save { $0.playsSounds = playsSounds } } }

    // MARK: Calls

    /// Whether to post notifications when calls start and end, while `showsNotifications` is on.
    /// See `CallPrompt`.
    var notifiesAboutCalls: Bool { didSet { save { $0.notifiesAboutCalls = notifiesAboutCalls } } }
    /// Whether to start and stop recording with calls, without asking. See `CallPrompt`.
    var recordsCallsAutomatically: Bool {
        didSet { save { $0.recordsCallsAutomatically = recordsCallsAutomatically } }
    }
    /// Which apps count as calls. Takes effect right away, even during a call. See `CallDetector`.
    var callApps: CallAppSelection { didSet { save { $0.callApps = callApps } } }

    // MARK: Transcription

    /// The language spoken, as an ISO 639-1 code; `nil` to detect it. Takes effect from the next
    /// recording.
    var language: String? { didSet { save { $0.language = language } } }
    /// Speaker names for multi-source recordings. Takes effect from the next transcription.
    var sourceLabels: SourceLabels { didSet { save { $0.sourceLabels = sourceLabels } } }
    /// Whether the people on the system audio are told apart once a recording ends. Takes effect
    /// from the next recording. Set it with `AppEnvironment.setIdentifiesSpeakers(_:)`, which
    /// downloads the model if needed.
    var identifiesSpeakers: Bool { didSet { save { $0.identifiesSpeakers = identifiesSpeakers } } }
    /// Whether the speakers told apart are named after what's said, by the summary model. Takes
    /// effect from the next transcription.
    var namesSpeakers: Bool { didSet { save { $0.namesSpeakers = namesSpeakers } } }
    /// Words to correct in transcripts. Takes effect from the next transcription; notes already
    /// written change only with `AppEnvironment.correctNotes(with:)`.
    var vocabulary: Vocabulary { didSet { save { $0.vocabulary = vocabulary } } }

    // MARK: Summary

    /// Whether notes get a summary. Takes effect from the next recording, even if the summarizer
    /// is unavailable right now; it's skipped until it becomes available.
    var summarizesNotes: Bool { didSet { save { $0.summarizesNotes = summarizesNotes } } }
    /// Every summary template, and those for recordings started by hand and for calls. Changes take
    /// effect from the next summary, including that of the recording in progress.
    var summaryTemplates: SummaryTemplateLibrary { didSet { save { $0.summaryTemplates = summaryTemplates } } }

    // MARK: Translation

    /// Whether notes are translated into `translationLanguage`. Takes effect from the next note.
    var translatesNotes: Bool { didSet { save { $0.translatesNotes = translatesNotes } } }
    /// The BCP 47 identifier of the language notes are translated into; kept while
    /// `translatesNotes` is off. Takes effect from the next note.
    var translationLanguage: String { didSet { save { $0.translationLanguage = translationLanguage } } }
    /// Whether the live text is translated into `translationLanguage` while recording, too. Takes
    /// effect from the next recording.
    var translatesLiveText: Bool { didSet { save { $0.translatesLiveText = translatesLiveText } } }

    // MARK: Design

    /// Whether a recording shows in the Dynamic Island rather than the menu bar. See `DynamicIsland`.
    var showsRecordingInDynamicIsland: Bool {
        didSet { save { $0.showsRecordingInDynamicIsland = showsRecordingInDynamicIsland } }
    }
    /// What the Dynamic Island shows, and where.
    var islandLayout: DynamicIsland.Layout { didSet { save { $0.islandLayout = islandLayout } } }

    // MARK: Notes

    /// Whether the notes are in Spotlight. See `NoteSpotlight`.
    var indexesNotesInSpotlight: Bool { didSet { save { $0.indexesNotesInSpotlight = indexesNotesInSpotlight } } }
    /// Whether Chat is in the sidebar and the View menu. Off, it doesn't read the notes. Set it with
    /// `AppEnvironment.setChatEnabled(_:)`, which stops Chat. See `NoteChat`.
    var isChatEnabled: Bool { didSet { save { $0.isChatEnabled = isChatEnabled } } }

    /// Called after any preference is set. See `AppEnvironment.applyPreferences()`.
    @ObservationIgnored var didChange: () -> Void = {}
    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        cancelsEcho = settings.cancelsEcho
        measuresTalkTime = settings.measuresTalkTime
        keepsAudioOnDisk = settings.keepsAudioOnDisk
        stillRecordingMinutes = settings.stillRecordingMinutes
        isRecordingShortcutEnabled = settings.isRecordingShortcutEnabled
        catchUpMinutes = settings.catchUpMinutes
        showsNotifications = settings.showsNotifications
        playsSounds = settings.playsSounds
        notifiesAboutCalls = settings.notifiesAboutCalls
        recordsCallsAutomatically = settings.recordsCallsAutomatically
        callApps = settings.callApps
        language = settings.language
        sourceLabels = settings.sourceLabels
        identifiesSpeakers = settings.identifiesSpeakers
        namesSpeakers = settings.namesSpeakers
        vocabulary = settings.vocabulary
        summarizesNotes = settings.summarizesNotes
        summaryTemplates = settings.summaryTemplates
        translatesNotes = settings.translatesNotes
        translationLanguage = settings.translationLanguage
        translatesLiveText = settings.translatesLiveText
        showsRecordingInDynamicIsland = settings.showsRecordingInDynamicIsland
        islandLayout = settings.islandLayout
        indexesNotesInSpotlight = settings.indexesNotesInSpotlight
        isChatEnabled = settings.isChatEnabled
    }

    /// What of these the recording coordinator follows; see `RecordingCoordinator.apply`.
    var coordinatorSettings: CoordinatorSettings {
        CoordinatorSettings(
            language: language,
            sourceLabels: sourceLabels,
            vocabulary: vocabulary,
            cancelsEcho: cancelsEcho,
            measuresTalkTime: measuresTalkTime,
            keepsAudioOnDisk: keepsAudioOnDisk,
            stillRecordingMinutes: stillRecordingMinutes,
            identifiesSpeakers: identifiesSpeakers,
            namesSpeakers: namesSpeakers,
            summarizesNotes: summarizesNotes,
            summaryTemplates: summaryTemplates,
            translatesNotes: translatesNotes,
            translationLanguage: translationLanguage,
            translatesLiveText: translatesLiveText
        )
    }

    private func save(_ write: (AppSettings) -> Void) {
        write(settings)
        didChange()
    }
}
