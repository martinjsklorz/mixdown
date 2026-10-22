import MixdownNotes

/// What correcting notes with the vocabulary did, in a sentence or two. For Settings and the
/// notification after adding a word.
enum VocabularyReport {
    static func message(for changes: NoteLibrary.VocabularyChanges) -> String {
        let corrected = changes.correctedNotes.count
        var message = corrected == 0 ? "No notes needed correcting." : "Corrected \(notes(corrected))."
        if let failure = changes.failures.first {
            message += " \(notes(changes.failures.count)) couldn't be changed: \(failure.message)"
        }
        return message
    }

    private static func notes(_ count: Int) -> String {
        count == 1 ? "1 note" : "\(count) notes"
    }
}
