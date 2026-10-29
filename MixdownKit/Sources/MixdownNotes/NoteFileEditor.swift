import Foundation
import MixdownCore

/// Changes notes' files one at a time, off the main thread. Each change reads a note, changes its
/// contents and writes it back, so two at once could each write back what they read and drop the
/// other's change: pinning a note while the vocabulary is applied to it, say, or applying the
/// vocabulary twice. One for the whole app, so every change goes through it.
///
/// Each method does what the `NoteLibrary` function of the same name does.
public actor NoteFileEditor {
    public init() {}

    /// See `NoteLibrary.rename(noteAt:to:)`.
    public func rename(noteAt url: URL, to title: String) throws -> URL {
        try NoteLibrary.rename(noteAt: url, to: title)
    }

    /// See `NoteLibrary.setPinned(_:noteAt:)`.
    public func setPinned(_ isPinned: Bool, noteAt url: URL) throws {
        try NoteLibrary.setPinned(isPinned, noteAt: url)
    }

    /// See `NoteLibrary.renameSpeaker(_:to:inNoteAt:)`.
    @discardableResult
    public func renameSpeaker(_ old: String, to new: String, inNoteAt url: URL) throws -> Bool {
        try NoteLibrary.renameSpeaker(old, to: new, inNoteAt: url)
    }

    /// See `NoteLibrary.applyVocabulary(_:toNotesIn:)`. Other changes wait until every note is
    /// done.
    public func applyVocabulary(
        _ vocabulary: Vocabulary,
        toNotesIn directory: URL
    ) throws
        -> NoteLibrary.VocabularyChanges
    {
        try NoteLibrary.applyVocabulary(vocabulary, toNotesIn: directory)
    }
}
