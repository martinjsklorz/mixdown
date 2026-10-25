import Foundation

/// Words the speech models get wrong, such as names and jargon, and how to write them. Applied to
/// each transcript before it's translated and summarized, and to notes already written on request.
public struct Vocabulary: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable, Identifiable {
        public var id: UUID
        /// How the word is written, like `"Kubernetes"`.
        public var term: String
        /// What the speech models write instead, like `"cooper netties"`. Matched as whole words,
        /// ignoring case and how much space is between them. Kept as typed, so blank and padded
        /// items can be there while one is being edited; they're trimmed when matched.
        public var soundsLike: [String]

        public init(id: UUID = UUID(), term: String, soundsLike: [String]) {
            self.id = id
            self.term = term
            self.soundsLike = soundsLike
        }

        /// `term` without surrounding whitespace.
        var trimmedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// The entries' terms, each once, in order, for models that can be told which words to expect.
    public var terms: [String] {
        var seen = Set<String>()
        return entries.map(\.trimmedTerm).filter { !$0.isEmpty && seen.insert(Replacer.key($0)).inserted }
    }

    /// Whether there's nothing to replace: no entry has both a term and something it sounds like.
    public var isEmpty: Bool { Replacer(self).isEmpty }

    /// The vocabulary with `soundsLike` added to the entry for `term`, compared ignoring case, or
    /// to a new entry at the end if there's none. Items that entry has already are left out.
    public func adding(_ soundsLike: String, for term: String) -> Vocabulary {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let soundsLike = soundsLike.trimmingCharacters(in: .whitespacesAndNewlines)
        var vocabulary = self
        guard let index = entries.firstIndex(where: { $0.trimmedTerm.caseInsensitiveCompare(term) == .orderedSame })
        else {
            vocabulary.entries.append(Entry(term: term, soundsLike: [soundsLike]))
            return vocabulary
        }
        let key = Replacer.key(soundsLike)
        var entry = vocabulary.entries[index]
        if !entry.soundsLike.contains(where: { Replacer.key($0) == key }) {
            entry.soundsLike.removeAll { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            entry.soundsLike.append(soundsLike)
        }
        vocabulary.entries[index] = entry
        return vocabulary
    }

    /// `text` with what each entry sounds like replaced by its term.
    public func apply(to text: String) -> String {
        Replacer(self).replace(in: text)
    }

    /// Whether `soundsLike` is a single word so short or common that replacing it everywhere is
    /// likely to change words that were right, like "the" or "and", so it's worth a warning.
    public static func isCommonWord(_ soundsLike: String) -> Bool {
        let words = soundsLike.split(whereSeparator: \.isWhitespace)
        guard words.count == 1, let word = words.first else { return false }
        let key = Replacer.key(String(word))
        return key.count(where: \.isLetter) <= 2 || commonWords.contains(key)
    }

    /// Short words common in English and German, the most frequent ones in speech.
    private static let commonWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one",
        "our", "out", "has", "him", "his", "how", "its", "may", "new", "now", "see", "two", "way", "who",
        "did", "get", "let", "say", "she", "too", "use", "yes", "yeah", "okay", "this", "that", "with",
        "have", "from", "they", "will", "what", "when", "your", "said", "each", "which", "their", "there",
        "then", "them", "these", "some", "would", "make", "like", "time", "just", "know", "take", "into",
        "year", "good", "could", "than", "other", "only", "also", "back", "after", "work", "well", "even",
        "want", "because", "right", "think", "really", "very", "here", "where", "about", "were", "been",
        "der", "die", "das", "und", "ist", "den", "dem", "des", "ein", "eine", "einen", "nicht", "sich",
        "mit", "auf", "für", "von", "auch", "als", "wie", "aber", "noch", "nur", "dann", "wenn", "oder",
        "schon", "jetzt", "hier", "dass", "sind", "wir", "ihr", "sie", "mal", "doch", "habe", "haben",
        "hat", "war", "kann", "muss", "bei", "nach", "aus", "vor", "zum", "zur", "ich", "man", "uns",
        "mir", "dir", "mich", "dich", "gut", "genau", "eben", "halt", "nein",
    ]

    /// `transcript` with `apply(to:)` applied to the text of each segment.
    public func apply(to transcript: Transcript) -> Transcript {
        let replacer = Replacer(self)
        guard !replacer.isEmpty else { return transcript }
        var transcript = transcript
        for index in transcript.segments.indices {
            transcript.segments[index].text = replacer.replace(in: transcript.segments[index].text)
        }
        return transcript
    }

    /// Replaces what a vocabulary's entries sound like with their terms, in one pass, so a term
    /// put in isn't matched again by another entry. Longer matches win over shorter ones.
    public struct Replacer {
        /// Terms by `key(_:)` of what they sound like, as `escape` made them.
        private let terms: [String: String]
        private let regex: NSRegularExpression?

        /// - Parameter escape: Applied to what the entries sound like and to their terms, for
        ///   text in which some characters are escaped, like Markdown.
        public init(_ vocabulary: Vocabulary, escaping escape: (String) -> String = { $0 }) {
            var terms: [String: String] = [:]
            for entry in vocabulary.entries {
                let term = entry.trimmedTerm
                guard !term.isEmpty else { continue }
                for soundsLike in entry.soundsLike {
                    let key = Self.key(escape(soundsLike.trimmingCharacters(in: .whitespacesAndNewlines)))
                    // The first entry wins when two sound alike.
                    if !key.isEmpty, terms[key] == nil { terms[key] = escape(term) }
                }
            }
            self.terms = terms

            // Terms are matched too, and left as they are, so a term that contains what an entry
            // sounds like isn't expanded again: "New York" for "york" stays "New York", and
            // applying the vocabulary twice changes nothing more than applying it once.
            var keys = Set(terms.keys)
            for entry in vocabulary.entries {
                let key = Self.key(escape(entry.trimmedTerm))
                if !key.isEmpty { keys.insert(key) }
            }

            // Longest first, as alternatives are tried in order.
            let alternatives = keys.sorted { ($0.count, $0) > ($1.count, $1) }.map { key in
                key.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: #"\h+"#)
            }
            // Not inside a word: no letter, digit or underscore right before or after.
            let pattern = #"(?<![\p{L}\p{N}_])(?:"# + alternatives.joined(separator: "|") + #")(?![\p{L}\p{N}_])"#
            self.regex =
                terms.isEmpty ? nil : try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }

        public var isEmpty: Bool { regex == nil }

        public func replace(in text: String) -> String {
            guard let regex else { return text }
            let string = text as NSString
            var result = ""
            var location = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)) {
                let found = string.substring(with: match.range)
                // A term is left as it is. So is a match without a term because matching ignores
                // case the regex's way, which can differ from folding's.
                guard let term = terms[Self.key(found)] else { continue }
                result += string.substring(with: NSRange(location: location, length: match.range.location - location))
                result += term
                location = match.range.location + match.range.length
            }
            guard location > 0 else { return text }
            return result + string.substring(from: location)
        }

        /// `text` with runs of whitespace as one space and case folded, for comparing.
        static func key(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .folding(options: [.caseInsensitive], locale: nil)
        }
    }
}
