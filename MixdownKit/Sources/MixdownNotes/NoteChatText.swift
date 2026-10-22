import Foundation

/// Splitting chat questions and notes into words to match.
enum NoteChatText {
    /// The words of `text` as written: runs of letters, digits and apostrophes.
    static func words(in text: some StringProtocol) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’")) }
            .filter { !$0.isEmpty }
    }

    /// The words of `text` to search for: folded to lowercase without accents, without
    /// `stopwords`, and with an English plural `s` dropped, so "Releases" finds "release".
    static func terms(in text: some StringProtocol) -> [String] {
        words(in: text).compactMap { word in
            var term = word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            if term.hasSuffix("'s") || term.hasSuffix("’s") { term.removeLast(2) }
            guard term.count > 1 || term.first?.isNumber == true, !stopwords.contains(term) else { return nil }
            if term.count > 3, term.hasSuffix("s"), !["ss", "us", "is"].contains(where: term.hasSuffix) {
                term.removeLast()
            }
            return term
        }
    }

    static func isStopword(_ word: String) -> Bool {
        stopwords.contains(word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
    }

    /// Words too common to search for, in English and German, folded like `terms(in:)`.
    static let stopwords: Set<String> = [
        // English
        "a", "about", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at", "be", "been",
        "before", "being", "but", "by", "can", "could", "did", "do", "does", "doing", "done", "for", "from", "get",
        "got", "had", "has", "have", "having", "he", "her", "here", "him", "his", "how", "i", "if", "in", "into",
        "is", "it", "its", "just", "let", "lets", "me", "my", "of", "on", "or", "our", "ours", "out", "over",
        "please", "said", "say", "she", "should", "so", "some", "tell", "than", "that", "the", "their", "them",
        "then", "there", "these", "they", "this", "those", "to", "up", "us", "was", "we", "were", "what", "when",
        "where", "which", "who", "whom", "why", "will", "with", "would", "you", "your", "happen", "happened",
        "talk", "talked", "discuss", "discussed", "mention", "mentioned", "know", "anything", "something",
        // German
        "aber", "alle", "als", "am", "an", "auch", "auf", "aus", "bei", "bin", "bis", "da", "das", "dass", "dem",
        "den", "der", "des", "die", "dies", "diese", "dieser", "doch", "du", "ein", "eine", "einem", "einen",
        "einer", "es", "fur", "gab", "gibt", "hab", "habe", "haben", "hat", "hatte", "hatten", "ich", "ihr", "im",
        "in", "ist", "ja", "kann", "mal", "man", "mein", "meine", "mir", "mit", "nach", "nicht", "noch", "nur",
        "oder", "ob", "sich", "sie", "sind", "so", "uber", "um", "und", "uns", "unser", "unsere", "von", "vor",
        "war", "waren", "was", "welche", "welcher", "wenn", "wer", "wie", "wir", "wo", "zu", "zum", "zur",
        "besprochen", "gesagt", "passiert",
    ]
}
