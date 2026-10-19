import Foundation

/// A finished recording, ready to be persisted.
public struct Note: Sendable, Equatable {
    public var title: String
    public var createdAt: Date
    public var duration: TimeInterval
    /// Every input that was recorded, in menu order. More than one for e.g. microphone + system audio.
    public var sources: [AudioInputDevice]
    public var engine: TranscriptionEngineInfo
    public var transcript: Transcript
    /// The transcript in another language, with its `language` set to that one. `nil` when
    /// translation is off, failed or the recording was in that language already.
    public var translation: Transcript?
    /// `nil` when summaries are off, unavailable or failed.
    public var summary: NoteSummary?
    /// Whether the user started the recording or Mixdown started it for a call by itself.
    public var trigger: RecordingTrigger
    /// Points the user marked while recording, in order of time.
    public var moments: [Moment]

    public init(
        title: String,
        createdAt: Date,
        duration: TimeInterval,
        sources: [AudioInputDevice],
        engine: TranscriptionEngineInfo,
        transcript: Transcript,
        translation: Transcript? = nil,
        summary: NoteSummary? = nil,
        trigger: RecordingTrigger = .manual,
        moments: [Moment] = []
    ) {
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.sources = sources
        self.engine = engine
        self.transcript = transcript
        self.translation = translation
        self.summary = summary
        self.trigger = trigger
        self.moments = moments
    }
}

/// How a recording was started. The raw value is what notes store.
public enum RecordingTrigger: String, Sendable, Equatable {
    /// By the user, e.g. from Record, the menu bar, the shortcut or a call notification.
    case manual
    /// By Mixdown, as a call started while it records calls automatically.
    case automatic
}

/// Persists notes somewhere the user can find them.
public protocol NoteWriting: Sendable {
    /// Writes the note and returns its location. Never overwrites an existing note.
    func write(_ note: Note) async throws -> URL
}

public enum NoteWritingError: LocalizedError, Equatable, Sendable {
    /// A recording finished while there was no folder to save it to.
    case noFolder

    public var errorDescription: String? {
        switch self {
        case .noFolder: "The notes folder isn't available, so the note couldn't be saved."
        }
    }
}
