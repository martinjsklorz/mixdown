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

    public init(
        title: String,
        createdAt: Date,
        duration: TimeInterval,
        sources: [AudioInputDevice],
        engine: TranscriptionEngineInfo,
        transcript: Transcript
    ) {
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.sources = sources
        self.engine = engine
        self.transcript = transcript
    }
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
