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
        /// Whether spellings close to `term` are corrected too, like "sklortz" for "Sklorz".
        public var fuzzy: Fuzziness

        public init(id: UUID = UUID(), term: String, soundsLike: [String], fuzzy: Fuzziness = .off) {
            self.id = id
            self.term = term
            self.soundsLike = soundsLike
            self.fuzzy = fuzzy
        }

        /// `term` without surrounding whitespace.
        var trimmedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }

        /// Adds `soundsLike` at the end, unless it's blank or there already, dropping blank items.
        /// Returns whether it was added.
        @discardableResult
        mutating func add(_ soundsLike: String) -> Bool {
            let key = Replacer.key(soundsLike)
            guard !key.isEmpty, !self.soundsLike.contains(where: { Replacer.key($0) == key }) else { return false }
            self.soundsLike.removeAll { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            self.soundsLike.append(soundsLike)
            return true
        }

        private enum CodingKeys: String, CodingKey {
            case id, term, soundsLike, fuzzy
        }

        /// Lenient, so an entry stored by another version still reads.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
            term = (try? container.decodeIfPresent(String.self, forKey: .term)) ?? ""
            soundsLike = container.decodeLossyArray([String].self, forKey: .soundsLike)
            fuzzy = (try? container.decodeIfPresent(Fuzziness.self, forKey: .fuzzy)) ?? .off
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    /// Lenient, so one odd entry doesn't lose all of the user's words.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = container.decodeLossyArray([Entry].self, forKey: .entries)
    }

    /// The entries' terms, each once, in order, for models that can be told which words to expect.
    public var terms: [String] {
        var seen = Set<String>()
        return entries.map(\.trimmedTerm).filter { !$0.isEmpty && seen.insert(Replacer.key($0)).inserted }
    }

    /// Whether there's nothing to replace: no entry has both a term and something it sounds like.
    /// Fuzzy matching doesn't count, as it only corrects new transcripts.
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
        vocabulary.entries[index].add(soundsLike)
        return vocabulary
    }

    /// The vocabulary with what was heard in each of `matches` added to its entry, so it's matched
    /// exactly from now on and the user can see it, and remove it if it's wrong. Matches of
    /// entries removed since are left out.
    public func learning(_ matches: [FuzzyMatch]) -> Vocabulary {
        var vocabulary = self
        for match in matches {
            guard let index = vocabulary.entries.firstIndex(where: { $0.id == match.entryID }) else { continue }
            vocabulary.entries[index].add(match.heard)
        }
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
    static let commonWords: Set<String> = [
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

    /// `transcript` with `apply(to:)` applied to the text of each segment. Then, in what that left
    /// alone, words spelled close to the term of an entry with `fuzzy` on are replaced by it too,
    /// unless `isKnownWord` says they're words of their own, like "clause" near "Claude". Also
    /// returns what was replaced that way, once each, to show the user.
    public func correct(
        _ transcript: Transcript,
        isKnownWord: (String) -> Bool
    ) -> (transcript: Transcript, fuzzyMatches: [FuzzyMatch]) {
        let replacer = Replacer(self)
        let fuzzyMatcher = FuzzyMatcher(self)
        guard !replacer.isEmpty || !fuzzyMatcher.isEmpty else { return (transcript, []) }
        var transcript = transcript
        var matches: [FuzzyMatch] = []
        for index in transcript.segments.indices {
            transcript.segments[index].text = replacer.replace(in: transcript.segments[index].text) { rest in
                fuzzyMatcher.isEmpty ? rest : fuzzyMatcher.replace(in: rest, isKnownWord: isKnownWord, found: &matches)
            }
        }
        var seen = Set<String>()
        matches = matches.filter { seen.insert("\($0.entryID) \(Replacer.key($0.heard))").inserted }
        return (transcript, matches)
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
            guard regex != nil else { return text }
            return replace(in: text) { $0 }
        }

        /// `text` with what entries sound like replaced, and `replaceRest` applied to each stretch
        /// of text between those replacements.
        func replace(in text: String, replacingRest replaceRest: (String) -> String) -> String {
            let string = text as NSString
            var result = ""
            var location = 0
            for match in regex?.matches(in: text, range: NSRange(location: 0, length: string.length)) ?? [] {
                let found = string.substring(with: match.range)
                // A term is left as it is. So is a match without a term because matching ignores
                // case the regex's way, which can differ from folding's.
                guard let term = terms[Self.key(found)] else { continue }
                let rest = string.substring(with: NSRange(location: location, length: match.range.location - location))
                result += replaceRest(rest)
                result += term
                location = match.range.location + match.range.length
            }
            return result + replaceRest(string.substring(from: location))
        }

        /// `text` with runs of whitespace as one space and case folded, for comparing.
        static func key(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .folding(options: [.caseInsensitive], locale: nil)
        }
    }
}
