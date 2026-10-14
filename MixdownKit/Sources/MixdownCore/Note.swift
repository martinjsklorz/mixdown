import Foundation

/// A finished recording, ready to be persisted.
public struct Note: Sendable, Equatable {
    public var title: String
    public var createdAt: Date
    public var duration: TimeInterval
    public var source: AudioInputDevice
    public var engine: TranscriptionEngineInfo
    public var transcript: Transcript

    public init(
        title: String,
        createdAt: Date,
        duration: TimeInterval,
        source: AudioInputDevice,
        engine: TranscriptionEngineInfo,
        transcript: Transcript
    ) {
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.source = source
        self.engine = engine
        self.transcript = transcript
    }
}

/// Persists notes somewhere the user can find them.
public protocol NoteWriting: Sendable {
    /// Writes the note and returns its location. Never overwrites an existing note.
    func write(_ note: Note) async throws -> URL
}
