import Foundation

extension Vocabulary {
    /// An entry in a vocabulary file. Reads Mixdown's files, `{"term", "soundsLike", "fuzzy"}`,
    /// and Muesli's custom words, `{"word", "replacement"}`: the replacement is the term and the
    /// word what it sounds like. Without a replacement, the word is the term.
    public struct FileEntry: Sendable, Equatable, Decodable {
        public var term: String
        public var soundsLike: [String]
        /// `nil` when the file doesn't say, so an import leaves the entry's setting as it is.
        public var fuzzy: Fuzziness?

        public init(term: String, soundsLike: [String], fuzzy: Fuzziness? = nil) {
            self.term = term
            self.soundsLike = soundsLike
            self.fuzzy = fuzzy
        }

        private enum CodingKeys: String, CodingKey {
            case term, soundsLike, fuzzy, word, replacement
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func string(_ key: CodingKeys) -> String? {
                let value = (try? container.decodeIfPresent(String.self, forKey: key))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value?.isEmpty == false ? value : nil
            }
            if let term = string(.term) {
                self.term = term
                // A single way it's heard, as someone may write it by hand.
                soundsLike =
                    string(.soundsLike).map { [$0] } ?? container.decodeLossyArray([String].self, forKey: .soundsLike)
                fuzzy = try? container.decodeIfPresent(Fuzziness.self, forKey: .fuzzy)
            } else if let word = string(.word) {
                // Muesli's matching threshold isn't taken over: fuzzy matching stays off until
                // the user turns it on.
                let replacement = string(.replacement)
                term = replacement ?? word
                soundsLike = replacement.map(Replacer.key) == Replacer.key(word) || replacement == nil ? [] : [word]
                fuzzy = nil
            } else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "An entry needs a term or a word.")
                )
            }
        }
    }

    /// Why a file couldn't be imported.
    public enum FileError: LocalizedError {
        case notAVocabulary

        public var errorDescription: String? {
            "The file isn't a vocabulary. Mixdown reads a JSON list of words, as it exports them, "
                + "and Muesli's custom words."
        }
    }

    /// The entries in a vocabulary file: a JSON array of `FileEntry`s, or an object with them under
    /// `entries`, as the settings store them. Entries without a term are left out.
    public static func fileEntries(from data: Data) throws -> [FileEntry] {
        struct Stored: Decodable {
            let entries: LossyArray<FileEntry>
        }
        let decoder = JSONDecoder()
        if let list = try? decoder.decode(LossyArray<FileEntry>.self, from: data) { return list.elements }
        if let stored = try? decoder.decode(Stored.self, from: data) { return stored.entries.elements }
        throw FileError.notAVocabulary
    }

    /// The entries as a JSON file to share, move to another Mac or keep in git: an array of
    /// `{"term", "soundsLike", "fuzzy"}` objects, one per entry, in order. IDs, blank items and
    /// `fuzzy` while it's off are left out, so the file only changes when the words do.
    public func fileContents() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func json(_ string: String) -> String {
            (try? encoder.encode(string)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        }
        let objects = entries.compactMap { entry -> String? in
            let term = entry.trimmedTerm
            guard !term.isEmpty else { return nil }
            let soundsLike = entry.soundsLike.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var fields = [
                #""term": "# + json(term),
                #""soundsLike": ["# + soundsLike.map(json).joined(separator: ", ") + "]",
            ]
            if entry.fuzzy != .off { fields.append(#""fuzzy": "# + json(entry.fuzzy.rawValue)) }
            return "  {\n" + fields.map { "    " + $0 }.joined(separator: ",\n") + "\n  }"
        }
        let text = objects.isEmpty ? "[]\n" : "[\n" + objects.joined(separator: ",\n") + "\n]\n"
        return Data(text.utf8)
    }

    /// What importing a file did.
    public struct Merge: Sendable, Equatable {
        public var vocabulary: Vocabulary
        /// Terms that weren't in the vocabulary.
        public var added = 0
        /// Terms the file added ways they're heard to, or changed `fuzzy` for.
        public var updated = 0
        /// Terms the file had nothing new for.
        public var unchanged = 0
        /// Only what's new: each added or updated term with the ways it's heard that weren't
        /// there before, to correct the notes already written with.
        public var newWords = Vocabulary()

        /// The counts in a sentence, like "3 added, 1 updated, 2 unchanged."
        public var summary: String {
            guard added + updated + unchanged > 0 else { return "There were no words in the file." }
            return "\(added) added, \(updated) updated, \(unchanged) unchanged."
        }
    }

    /// The vocabulary with `imported` merged in. A term that's in it already, ignoring case, gets
    /// the ways it's heard it doesn't have yet, and the file's `fuzzy`, if it has one. Other terms
    /// are added at the end. Nothing is removed.
    public func merging(_ imported: [FileEntry]) -> Merge {
        enum Outcome: Comparable { case unchanged, updated, added }
        var merge = Merge(vocabulary: self)
        // By term, the most a term got from the file, which can have it more than once.
        var outcomes: [String: Outcome] = [:]
        for item in imported {
            let term = item.term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Replacer.key(term)
            guard !key.isEmpty else { continue }
            let soundsLike = item.soundsLike.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            let index: Int
            var outcome: Outcome
            if let existing = merge.vocabulary.entries.firstIndex(where: { Replacer.key($0.trimmedTerm) == key }) {
                index = existing
                outcome = .unchanged
            } else {
                merge.vocabulary.entries.append(Entry(term: term, soundsLike: []))
                index = merge.vocabulary.entries.count - 1
                outcome = .added
            }

            var entry = merge.vocabulary.entries[index]
            for item in soundsLike where entry.add(item) {
                merge.newWords = merge.newWords.adding(item, for: entry.trimmedTerm)
            }
            if let fuzzy = item.fuzzy { entry.fuzzy = fuzzy }
            if outcome == .unchanged, entry != merge.vocabulary.entries[index] { outcome = .updated }
            merge.vocabulary.entries[index] = entry
            outcomes[key] = max(outcomes[key] ?? .unchanged, outcome)
        }
        merge.added = outcomes.values.count { $0 == .added }
        merge.updated = outcomes.values.count { $0 == .updated }
        merge.unchanged = outcomes.values.count { $0 == .unchanged }
        return merge
    }
}
