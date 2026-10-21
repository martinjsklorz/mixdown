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

            // Longest first, as alternatives are tried in order.
            let alternatives = terms.keys.sorted { ($0.count, $0) > ($1.count, $1) }.map { key in
                key.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: #"\h+"#)
            }
            // Not inside a word: no letter, digit or underscore right before or after.
            let pattern = #"(?<![\p{L}\p{N}_])(?:"# + alternatives.joined(separator: "|") + #")(?![\p{L}\p{N}_])"#
            self.regex =
                alternatives.isEmpty ? nil : try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }

        public var isEmpty: Bool { regex == nil }

        public func replace(in text: String) -> String {
            guard let regex else { return text }
            let string = text as NSString
            var result = ""
            var location = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)) {
                let found = string.substring(with: match.range)
                // Matching ignores case the regex's way, which can differ from folding's, so a
                // match without a term is left as it is.
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
