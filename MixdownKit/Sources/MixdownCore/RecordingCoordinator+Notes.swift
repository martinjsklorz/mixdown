import Foundation

/// The settings and state of `pipeline`, which makes and saves the notes.
extension RecordingCoordinator {
    /// Saves finished notes. `nil` while there's no folder to save to; recording waits for one.
    /// Setting it saves `pendingNotes`.
    public var noteWriter: (any NoteWriting)? {
        get { pipeline.saver.noteWriter }
        set { pipeline.saver.noteWriter = newValue }
    }

    /// Finished notes that couldn't be saved yet, oldest first, e.g. because the notes folder is on
    /// a drive that was disconnected or asleep when the recording finished. They're saved as soon
    /// as there's a `noteWriter` again, and retried every `pendingNoteRetryInterval` meanwhile.
    /// Only kept in memory, so they're lost if the app quits.
    public var pendingNotes: [Note] { pipeline.saver.pendingNotes }

    /// True while `pendingNotes` are being written.
    public var isSavingPendingNotes: Bool { pipeline.saver.isSaving }

    /// Location of the most recently written note.
    public var lastNoteURL: URL? { pipeline.saver.lastNoteURL }

    /// How long to wait before trying to save `pendingNotes` again, while there's a `noteWriter`
    /// that failed to write them.
    var pendingNoteRetryInterval: Duration {
        get { pipeline.saver.retryInterval }
        set { pipeline.saver.retryInterval = newValue }
    }

    /// Removes and returns `pendingNotes`, for the coordinator replacing this one. Returns nothing
    /// while they're being saved, as they may already be written.
    public func takePendingNotes() -> [Note] {
        pipeline.saver.takePendingNotes()
    }

    /// Adds a summary to each note. `nil` while summaries are off.
    public var summarizer: (any Summarizer)? {
        get { pipeline.summarizer }
        set { pipeline.summarizer = newValue }
    }

    /// Whether notes are named after their summary's title. Off, they're named after the time
    /// recorded, or an imported file's name. Read once the note is summarized.
    public var titlesNotesFromSummary: Bool {
        get { pipeline.titlesNotesFromSummary }
        set { pipeline.titlesNotesFromSummary = newValue }
    }

    /// Adds a translation of the transcript to each note, into `translationLanguage`. Summaries are
    /// then made from the translation, so they're in that language too.
    public var translator: (any Translator)? {
        get { pipeline.translator }
        set { pipeline.translator = newValue }
    }

    /// The BCP 47 identifier of the language to translate notes into, e.g. `"de"`; `nil` while
    /// translation is off. Read once the recording is transcribed.
    public var translationLanguage: String? {
        get { pipeline.translationLanguage }
        set { pipeline.translationLanguage = newValue }
    }

    /// Speaker names for multi-source recordings.
    public var sourceLabels: SourceLabels {
        get { pipeline.sourceLabels }
        set { pipeline.sourceLabels = newValue }
    }

    /// Words to correct in each transcript, before it's translated and summarized. Read once the
    /// recording is transcribed.
    public var vocabulary: Vocabulary {
        get { pipeline.vocabulary }
        set { pipeline.vocabulary = newValue }
    }

    /// Whether the spell checker knows a word, in a language if one is given, so fuzzy vocabulary
    /// entries don't change words that were right. Without one, only short and common words are
    /// left alone.
    public var isKnownWord: @MainActor (_ word: String, _ language: String?) -> Bool {
        get { pipeline.isKnownWord }
        set { pipeline.isKnownWord = newValue }
    }

    /// Called with what fuzzy vocabulary entries corrected in a transcript, to add to `vocabulary`
    /// with `Vocabulary.learning(_:)`.
    public var didMatchFuzzily: @MainActor ([Vocabulary.FuzzyMatch]) -> Void {
        get { pipeline.didMatchFuzzily }
        set { pipeline.didMatchFuzzily = newValue }
    }

    /// Renames the speakers `speakerDiarizer` told apart after what's said, where it can tell who
    /// they are; `nil` while that's off. Read once the recording is transcribed.
    public var speakerNamer: (any Summarizer)? {
        get { pipeline.speakerNamer }
        set { pipeline.speakerNamer = newValue }
    }

    /// Shows what the pipeline is doing as the phase.
    func pipelineDidChange(to stage: NotePipeline.Stage) {
        switch stage {
        case .transcribing(let progress): phase = .transcribing(progress: progress)
        case .identifyingSpeakers: phase = .identifyingSpeakers
        case .translating: phase = .translating
        case .summarizing: phase = .summarizing
        }
    }
}
