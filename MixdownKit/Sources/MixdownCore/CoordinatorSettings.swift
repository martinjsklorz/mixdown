import Foundation

/// The user's choices a `RecordingCoordinator` follows, as Settings has them. `apply(_:summarizer:diarizer:)`
/// turns them into the coordinator's own properties, so that mapping is in one place.
public struct CoordinatorSettings: Equatable, Sendable {
    /// The language to transcribe in; `nil` to detect it.
    public var language: String?
    public var sourceLabels: SourceLabels
    public var vocabulary: Vocabulary
    public var cancelsEcho: Bool
    public var measuresTalkTime: Bool
    public var keepsAudioOnDisk: Bool
    /// Minutes without speech before asking whether still recording; 0 never to ask.
    public var stillRecordingMinutes: Int
    public var identifiesSpeakers: Bool
    /// Whether speakers told apart are named from the conversation, which also needs
    /// `identifiesSpeakers`.
    public var namesSpeakers: Bool
    public var summarizesNotes: Bool
    /// Whether notes are named after their summary's title, while `summarizesNotes`.
    public var titlesNotesFromSummary: Bool
    public var summaryTemplates: SummaryTemplateLibrary
    public var translatesNotes: Bool
    /// The language notes are translated into while `translatesNotes`.
    public var translationLanguage: String
    public var translatesLiveText: Bool

    public init(
        language: String? = nil,
        sourceLabels: SourceLabels = SourceLabels(),
        vocabulary: Vocabulary = Vocabulary(),
        cancelsEcho: Bool = true,
        measuresTalkTime: Bool = false,
        keepsAudioOnDisk: Bool = true,
        stillRecordingMinutes: Int = 15,
        identifiesSpeakers: Bool = false,
        namesSpeakers: Bool = true,
        summarizesNotes: Bool = true,
        titlesNotesFromSummary: Bool = true,
        summaryTemplates: SummaryTemplateLibrary = SummaryTemplateLibrary(),
        translatesNotes: Bool = false,
        translationLanguage: String = "",
        translatesLiveText: Bool = true
    ) {
        self.language = language
        self.sourceLabels = sourceLabels
        self.vocabulary = vocabulary
        self.cancelsEcho = cancelsEcho
        self.measuresTalkTime = measuresTalkTime
        self.keepsAudioOnDisk = keepsAudioOnDisk
        self.stillRecordingMinutes = stillRecordingMinutes
        self.identifiesSpeakers = identifiesSpeakers
        self.namesSpeakers = namesSpeakers
        self.summarizesNotes = summarizesNotes
        self.titlesNotesFromSummary = titlesNotesFromSummary
        self.summaryTemplates = summaryTemplates
        self.translatesNotes = translatesNotes
        self.translationLanguage = translationLanguage
        self.translatesLiveText = translatesLiveText
    }
}

extension RecordingCoordinator {
    /// Follows `settings` from now on, summarizing and naming speakers with `summarizer` and
    /// telling them apart with `diarizer` where they call for that. Assigning a value the
    /// coordinator already has changes nothing, so this can run on every change to them.
    public func apply(
        _ settings: CoordinatorSettings,
        summarizer: (any Summarizer)?,
        diarizer: (any SpeakerDiarizer)?
    ) {
        options.language = settings.language
        sourceLabels = settings.sourceLabels
        vocabulary = settings.vocabulary
        cancelsEcho = settings.cancelsEcho
        measuresTalkTime = settings.measuresTalkTime
        keepsAudioOnDisk = settings.keepsAudioOnDisk
        let minutes = settings.stillRecordingMinutes
        stillRecordingDelay = minutes > 0 ? .seconds(minutes * 60) : nil
        speakerDiarizer = settings.identifiesSpeakers ? diarizer : nil
        speakerNamer = settings.identifiesSpeakers && settings.namesSpeakers ? summarizer : nil
        self.summarizer = settings.summarizesNotes ? summarizer : nil
        titlesNotesFromSummary = settings.titlesNotesFromSummary
        summaryTemplate = settings.summaryTemplates.recordingTemplate
        callSummaryTemplate = settings.summaryTemplates.callTemplate
        updateRecordingSummaryTemplate(from: settings.summaryTemplates.templates)
        translationLanguage = settings.translatesNotes ? settings.translationLanguage : nil
        translatesLiveText = settings.translatesLiveText
    }
}
