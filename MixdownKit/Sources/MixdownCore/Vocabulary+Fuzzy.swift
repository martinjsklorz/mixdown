import Foundation

extension Vocabulary {
    /// How close a spelling has to be to an entry's term to be corrected to it, by Jaro-Winkler
    /// similarity. Off unless the user turns it on for an entry, as ordinary words come close to
    /// names too: "marketing" scores 0.92 against "Martin", "clause" 0.93 against "Claude".
    public enum Fuzziness: String, Sendable, Codable, CaseIterable {
        case off, strict, loose

        /// The lowest similarity corrected, from 0 to 1; `nil` while off.
        var threshold: Double? {
            switch self {
            case .off: nil
            case .strict: 0.93
            case .loose: 0.88
            }
        }
    }

    /// A spelling a fuzzy entry corrected: what was heard, and the entry it was corrected to.
    public struct FuzzyMatch: Sendable, Equatable {
        /// As it was in the transcript, case folded and with runs of whitespace as one space.
        public var heard: String
        public var entryID: UUID
        public var term: String

        public init(heard: String, entryID: UUID, term: String) {
            self.heard = heard
            self.entryID = entryID
            self.term = term
        }
    }

    /// Replaces spellings close to the terms of entries with `fuzzy` on. A run of words matches a
    /// term of as many words when each is the same as the term's word or close to it, without
    /// punctuation between them. Words that are close but short, common or a word of any entry
    /// are left alone, and so are words the spell checker knows.
    struct FuzzyMatcher {
        /// Fewest letters in a word that's corrected, and in the term's word it's corrected to.
        /// Short words come close to too many others.
        static let minimumLetters = 5

        private struct Target {
            let entryID: UUID
            let term: String
            /// The term's words, case folded.
            let words: [String]
            let threshold: Double
        }

        /// Longest first, as longer matches win.
        private let targets: [Target]
        /// The words of every entry's term and of what it sounds like, case folded. These are
        /// meant as they are, so they're never corrected to another.
        private let entryWords: Set<String>

        init(_ vocabulary: Vocabulary) {
            targets = vocabulary.entries.compactMap { entry -> Target? in
                guard let threshold = entry.fuzzy.threshold, let words = Self.words(ofTerm: entry.trimmedTerm) else {
                    return nil
                }
                return Target(entryID: entry.id, term: entry.trimmedTerm, words: words, threshold: threshold)
            }
            .sorted { $0.words.count > $1.words.count }
            entryWords = Set(
                vocabulary.entries.flatMap { [$0.term] + $0.soundsLike }
                    .flatMap { Replacer.key($0).split(separator: " ").map(String.init) }
            )
        }

        var isEmpty: Bool { targets.isEmpty }

        /// `term` split into case-folded words, if it can be matched fuzzily: it's only letters
        /// and digits, in words separated by spaces, and at least one word is long enough.
        static func words(ofTerm term: String) -> [String]? {
            let words = Replacer.key(term).split(separator: " ").map(String.init)
            guard !words.isEmpty, words.allSatisfy({ $0.allSatisfy(isWordCharacter) }),
                words.contains(where: { $0.count >= minimumLetters && $0.allSatisfy(\.isLetter) })
            else { return nil }
            return words
        }

        /// `text` with runs of words close to a target's term replaced by it, adding each
        /// replacement to `found`.
        func replace(in text: String, isKnownWord: (String) -> Bool, found: inout [FuzzyMatch]) -> String {
            let words = Self.wordRanges(in: text)
            guard !words.isEmpty else { return text }
            var result = ""
            var end = text.startIndex
            var index = 0
            while index < words.count {
                guard let (target, count) = bestTarget(at: index, in: words, of: text, isKnownWord: isKnownWord)
                else {
                    index += 1
                    continue
                }
                let range = words[index].lowerBound..<words[index + count - 1].upperBound
                result += text[end..<range.lowerBound]
                result += target.term
                let heard = Replacer.key(String(text[range]))
                found.append(FuzzyMatch(heard: heard, entryID: target.entryID, term: target.term))
                end = range.upperBound
                index += count
            }
            result += text[end...]
            return result
        }

        /// The target the words from `index` on are closest to, and how many words that takes:
        /// the longest one, then the closest.
        private func bestTarget(
            at index: Int,
            in words: [Range<String.Index>],
            of text: String,
            isKnownWord: (String) -> Bool
        ) -> (Target, Int)? {
            var candidates: [(target: Target, score: Double)] = []
            for target in targets where index + target.words.count <= words.count {
                let run = words[index..<(index + target.words.count)]
                // Words of a term are only matched while just spaces are between them.
                let joined = zip(run, run.dropFirst()).allSatisfy { previous, next in
                    let between = text[previous.upperBound..<next.lowerBound]
                    return between.allSatisfy { $0.isWhitespace && !$0.isNewline }
                }
                guard joined, let score = score(of: run.map { String(text[$0]) }, against: target) else { continue }
                candidates.append((target, score))
            }
            // Stable, so the first entry wins a tie.
            let ranked = candidates.enumerated().sorted { a, b in
                (a.element.target.words.count, a.element.score, -a.offset)
                    > (b.element.target.words.count, b.element.score, -b.offset)
            }
            // The spell checker last, as it's the slowest, and only for words that differ.
            for (_, candidate) in ranked {
                let run = words[index..<(index + candidate.target.words.count)].map { String(text[$0]) }
                let changed = zip(run, candidate.target.words).filter { Replacer.key($0) != $1 }.map(\.0)
                if !changed.contains(where: isKnownWord) { return (candidate.target, run.count) }
            }
            return nil
        }

        /// How close `words` are to the target's: the lowest similarity of a word to the term's
        /// word in its place, or `nil` if one isn't close enough or none differs.
        private func score(of words: [String], against target: Target) -> Double? {
            var lowest = 1.0
            var differs = false
            for (word, targetWord) in zip(words, target.words) {
                let key = Replacer.key(word)
                guard key != targetWord else { continue }
                differs = true
                guard key.count >= Self.minimumLetters, targetWord.count >= Self.minimumLetters,
                    key.allSatisfy(\.isLetter), !Vocabulary.commonWords.contains(key), !entryWords.contains(key)
                else { return nil }
                let similarity = Self.jaroWinkler(key, targetWord)
                guard similarity >= target.threshold else { return nil }
                lowest = min(lowest, similarity)
            }
            return differs ? lowest : nil
        }

        /// The ranges of the words in `text`: runs of letters, digits and underscores, as the
        /// exact matches take them.
        private static func wordRanges(in text: String) -> [Range<String.Index>] {
            var ranges: [Range<String.Index>] = []
            var start: String.Index?
            for index in text.indices {
                if isWordCharacter(text[index]) {
                    if start == nil { start = index }
                } else if let wordStart = start {
                    ranges.append(wordStart..<index)
                    start = nil
                }
            }
            if let start { ranges.append(start..<text.endIndex) }
            return ranges
        }

        private static func isWordCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_"
        }

        /// The Jaro-Winkler similarity of `a` and `b`, from 0 to 1: the share of letters they
        /// have in common in about the same order, with a bonus for the first four being the same.
        static func jaroWinkler(_ a: String, _ b: String) -> Double {
            let a = Array(a)
            let b = Array(b)
            guard a != b else { return 1 }
            guard !a.isEmpty, !b.isEmpty else { return 0 }

            // Letters match when they're the same and no further apart than this.
            let window = max(max(a.count, b.count) / 2 - 1, 0)
            var aMatched = [Bool](repeating: false, count: a.count)
            var bMatched = [Bool](repeating: false, count: b.count)
            var matches = 0
            for i in a.indices {
                for j in max(0, i - window)..<min(b.count, i + window + 1) where !bMatched[j] && a[i] == b[j] {
                    aMatched[i] = true
                    bMatched[j] = true
                    matches += 1
                    break
                }
            }
            guard matches > 0 else { return 0 }

            // Matched letters that are in a different order, counted in pairs.
            var outOfOrder = 0
            var j = 0
            for i in a.indices where aMatched[i] {
                while !bMatched[j] { j += 1 }
                if a[i] != b[j] { outOfOrder += 1 }
                j += 1
            }
            let m = Double(matches)
            let jaro = (m / Double(a.count) + m / Double(b.count) + (m - Double(outOfOrder) / 2) / m) / 3

            let prefix = zip(a.prefix(4), b.prefix(4)).prefix { $0 == $1 }.count
            return jaro + Double(prefix) * 0.1 * (1 - jaro)
        }
    }
}

extension Vocabulary.Entry {
    /// Whether `fuzzy` can do anything for this entry: its term is letters and digits only, with
    /// a word of at least five letters.
    public var canMatchFuzzily: Bool { Vocabulary.FuzzyMatcher.words(ofTerm: trimmedTerm) != nil }
}
