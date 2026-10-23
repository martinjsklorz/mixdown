import Foundation
import MixdownCore

/// What Chat finds answers in: every note in short passages of a few lines, each with an
/// embedding of its meaning. A question is matched against them both by its words and by its
/// meaning, so "When do we ship?" finds "The release moves to Friday."
///
/// Kept between launches, so only notes that changed are embedded again, each note in a file of
/// its own, so a change only rewrites that note's embeddings.
public struct NoteChatIndex: Sendable {
    /// A few consecutive lines of one section of a note.
    public struct Passage: Sendable, Equatable {
        public var noteURL: URL
        /// The number of its first line in `NoteSearchIndex.lines(of:)`, to show the note at.
        public var line: Int
        /// The heading of the section it's in, like "Action Items" or "Transcript".
        public var section: String?
        /// When its first line was said, like `00:12:34`, for transcript lines.
        public var time: String?
        /// Its lines as plain text, one per line.
        public var text: String
        /// `nil` until it's embedded, and for text no model covers.
        public var embedding: TextEmbedding?
        /// How often each search term (see `NoteChatText.terms(in:)`) occurs in `text` and the
        /// note's title. Worked out again rather than saved.
        var terms: [String: Int]

        init(noteURL: URL, line: Int, section: String?, time: String?, text: String, title: String) {
            self.noteURL = noteURL
            self.line = line
            self.section = section
            self.time = time
            self.text = text
            self.terms = Self.terms(text: text, title: title)
        }

        /// Whether it's from a summary rather than a transcript, which makes it a good overview.
        var isSummary: Bool {
            ![MarkdownNoteRenderer.transcriptHeading, MarkdownNoteRenderer.translationHeading].contains(section ?? "")
        }

        fileprivate static func terms(text: String, title: String) -> [String: Int] {
            var terms: [String: Int] = [:]
            for term in NoteChatText.terms(in: text) + NoteChatText.terms(in: title) { terms[term, default: 0] += 1 }
            return terms
        }
    }

    struct Entry: Sendable, Codable {
        /// `NoteSearchIndex.fingerprint(of:)` of the note when its passages were made.
        var fingerprint: String
        var title: String
        var passages: [Passage]
        /// Whether its passages went to the embedder. Notes it couldn't take, e.g. as its model
        /// wasn't downloaded, are embedded on a later update.
        var isEmbedded: Bool
    }

    /// Bumped when passages are made differently, so an index saved by an older version is made
    /// again.
    static let formatVersion = 1
    /// Most lines in a passage.
    static let maxLinesPerPassage = 3
    /// Most words in a passage. A line longer than this is split into several. The embedding
    /// models read about 256 tokens.
    static let maxWordsPerPassage = 80

    /// By the note's URL.
    var entries: [String: Entry] = [:]
    /// Notes added or changed, and notes removed, since the last `save(in:)`.
    private(set) var unsavedIDs: Set<String> = []
    private var removedIDs: Set<String> = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// How many notes it has.
    public var noteCount: Int { entries.count }

    /// The models the passages were embedded with, to embed a question with each.
    public var embeddingModels: Set<String> {
        Set(entries.values.lazy.flatMap(\.passages).compactMap(\.embedding?.model))
    }

    // MARK: Passages

    /// `note` in passages: up to `maxLinesPerPassage` consecutive lines of one section, of up to
    /// `maxWordsPerPassage` words together, in order.
    public static func passages(of note: NoteDocument) -> [Passage] {
        var passages: [Passage] = []
        var lines: [String] = []
        var first: (number: Int, line: NoteSearchIndex.Line)?
        var wordCount = 0

        func flush() {
            if let first, !lines.isEmpty {
                passages.append(
                    Passage(
                        noteURL: note.url,
                        line: first.number,
                        section: first.line.section,
                        time: first.line.time,
                        text: lines.joined(separator: "\n"),
                        title: note.title
                    )
                )
            }
            lines = []
            first = nil
            wordCount = 0
        }

        for (number, line) in NoteSearchIndex.lines(of: note).enumerated() {
            var words = line.text.split(separator: " ")[...]
            // A long line becomes several passages, all pointing at it.
            while words.count > maxWordsPerPassage {
                flush()
                first = (number, line)
                lines = [words.prefix(maxWordsPerPassage).joined(separator: " ")]
                flush()
                words = words.dropFirst(maxWordsPerPassage)
            }
            if first?.line.section != line.section || lines.count >= maxLinesPerPassage
                || wordCount + words.count > maxWordsPerPassage
            {
                flush()
            }
            if first == nil { first = (number, line) }
            lines.append(words.joined(separator: " "))
            wordCount += words.count
        }
        flush()
        return passages
    }

    // MARK: Updating

    /// A note made into passages by `index(_:embedder:)`, ready to `insert(_:)`.
    public struct IndexedNote: Sendable {
        var id: String
        var entry: Entry
        /// Whether the embedder failed, so the note was indexed without embeddings. Later notes
        /// may as well be indexed without it too.
        public var embedderFailed: Bool
    }

    /// The notes of `notes` that are new or changed since they were indexed, each once, in order.
    /// With `canEmbed`, also those indexed without embeddings as the embedder failed.
    public func notesToIndex(_ notes: [NoteDocument], canEmbed: Bool) -> [NoteDocument] {
        var seen = Set<String>()
        return notes.filter { note in
            let id = note.url.absoluteString
            guard seen.insert(id).inserted else { return false }
            guard let entry = entries[id] else { return true }
            return entry.fingerprint != NoteSearchIndex.fingerprint(of: note) || (canEmbed && !entry.isEmbedded)
        }
    }

    /// Drops the notes that aren't in `notes`.
    public mutating func removeNotes(notIn notes: [NoteDocument]) {
        let ids = Set(notes.map(\.url.absoluteString))
        for id in entries.keys where !ids.contains(id) {
            entries[id] = nil
            unsavedIDs.remove(id)
            removedIDs.insert(id)
        }
    }

    /// `note` in passages, embedded with `embedder` if there is one. If the embedder fails, the
    /// passages are kept without embeddings, to be embedded on a later update. Throws only
    /// `CancellationError`.
    public static func index(_ note: NoteDocument, embedder: (any TextEmbedder)?) async throws -> IndexedNote {
        try Task.checkCancellation()
        var passages = passages(of: note)
        var embedderFailed = false
        if let embedder, !passages.isEmpty {
            do {
                let embeddings = try await embedder.embed(passages.map(\.text))
                for index in passages.indices where index < embeddings.count {
                    passages[index].embedding = embeddings[index]
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                embedderFailed = true
            }
        }
        let entry = Entry(
            fingerprint: NoteSearchIndex.fingerprint(of: note),
            title: note.title,
            passages: passages,
            isEmbedded: embedder != nil && !embedderFailed
        )
        return IndexedNote(id: note.url.absoluteString, entry: entry, embedderFailed: embedderFailed)
    }

    /// Adds a note made into passages, replacing what the index had of it.
    public mutating func insert(_ note: IndexedNote) {
        entries[note.id] = note.entry
        removedIDs.remove(note.id)
        unsavedIDs.insert(note.id)
    }

    /// Brings the index in line with `notes` with the methods above, calling `progress` after
    /// each note it indexes with how many of them are done. Stops using `embedder` once it fails.
    /// Throws only `CancellationError`, keeping the notes done so far.
    ///
    /// Holds on to the index while it waits for the embedder, so an actor that keeps one should
    /// rather call those methods itself, and search between them.
    public mutating func update(
        to notes: [NoteDocument],
        embedder: (any TextEmbedder)?,
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws {
        var embedder = embedder
        removeNotes(notIn: notes)
        let pending = notesToIndex(notes, canEmbed: embedder != nil)
        for (done, note) in pending.enumerated() {
            let indexed = try await Self.index(note, embedder: embedder)
            if indexed.embedderFailed { embedder = nil }
            insert(indexed)
            progress(done + 1, pending.count)
        }
    }

    // MARK: Searching

    /// How much more a passage counts the earlier it ranks, in reciprocal rank fusion.
    static let rankOffset = 60.0
    /// How many of the passages most similar in meaning are ranked.
    static let maxSimilarPassages = 200

    /// The passages of `notes` that best answer `query`, best first, at most `perNote` of a note.
    ///
    /// Ranks the passages by the query's words (BM25) and by similarity to `queryEmbeddings`
    /// (one per model in `embeddingModels`), and merges both rankings by reciprocal rank fusion.
    /// A query with no words to search for, like "What happened last week?", gets an overview: the
    /// summaries of as many of the newest notes as `limit` allows.
    public func search(
        _ query: String,
        queryEmbeddings: [TextEmbedding],
        in notes: [NoteDocument],
        limit: Int,
        perNote: Int = 4
    ) -> [Passage] {
        let ids = Set(notes.map(\.url.absoluteString))
        let candidates = entries.filter { ids.contains($0.key) }.values.flatMap(\.passages)
        let queryTerms = Array(Set(NoteChatText.terms(in: query)))
        guard !queryTerms.isEmpty else { return overview(of: notes, limit: limit, perNote: perNote) }

        var scores = [Double](repeating: 0, count: candidates.count)
        let byWords = Self.bm25(queryTerms, candidates)
            .enumerated().filter { $0.element > 0 }
            .sorted { $0.element > $1.element }
        for (rank, item) in byWords.enumerated() { scores[item.offset] += 1 / (Self.rankOffset + Double(rank + 1)) }

        let queryVectors = Dictionary(queryEmbeddings.map { ($0.model, $0) }, uniquingKeysWith: { first, _ in first })
        let byMeaning = candidates.enumerated().compactMap { index, passage -> (Int, Float)? in
            guard let embedding = passage.embedding, let query = queryVectors[embedding.model] else { return nil }
            return (index, query.similarity(to: embedding.vector))
        }
        .sorted { $0.1 > $1.1 }
        .prefix(Self.maxSimilarPassages)
        for (rank, item) in byMeaning.enumerated() { scores[item.0] += 1 / (Self.rankOffset + Double(rank + 1)) }

        // Ties (passages neither ranking found) in the notes' order, then by line.
        let order = Dictionary(notes.enumerated().map { ($1.url, $0) }, uniquingKeysWith: { first, _ in first })
        let ranked = candidates.indices.filter { scores[$0] > 0 }.sorted {
            if scores[$0] != scores[$1] { return scores[$0] > scores[$1] }
            let (left, right) = (candidates[$0], candidates[$1])
            return (order[left.noteURL] ?? 0, left.line) < (order[right.noteURL] ?? 0, right.line)
        }
        return Self.capped(ranked.lazy.map { candidates[$0] }, limit: limit, perNote: perNote)
    }

    /// The summaries of `notes`, or the start of the notes without one: the first passage of each
    /// note in their order, then the second of each, and so on, so an overview covers up to `limit`
    /// notes rather than a few in depth. Answers trim from the end, so the first passages go last.
    private func overview(of notes: [NoteDocument], limit: Int, perNote: Int) -> [Passage] {
        var seen = Set<String>()
        var byNote: [[Passage]] = []
        // No more notes than `limit` get a passage in.
        for note in notes where byNote.count < limit {
            let id = note.url.absoluteString
            guard seen.insert(id).inserted, let passages = entries[id]?.passages, !passages.isEmpty else { continue }
            let summary = passages.filter(\.isSummary)
            byNote.append(Array((summary.isEmpty ? passages : summary).prefix(perNote)))
        }
        var result: [Passage] = []
        for round in 0..<perNote {
            for passages in byNote where passages.count > round {
                guard result.count < limit else { return result }
                result.append(passages[round])
            }
        }
        return result
    }

    private static func capped(_ passages: some Sequence<Passage>, limit: Int, perNote: Int) -> [Passage] {
        var counts: [URL: Int] = [:]
        var result: [Passage] = []
        for passage in passages where result.count < limit {
            guard counts[passage.noteURL, default: 0] < perNote else { continue }
            counts[passage.noteURL, default: 0] += 1
            result.append(passage)
        }
        return result
    }

    /// The BM25 score of each of `passages` for `queryTerms`.
    static func bm25(_ queryTerms: [String], _ passages: [Passage]) -> [Double] {
        let k1 = 1.2
        let b = 0.75
        let count = Double(passages.count)
        let lengths = passages.map { Double($0.terms.values.reduce(0, +)) }
        let averageLength = max(lengths.reduce(0, +) / max(count, 1), 1)
        let weights = queryTerms.map { term in
            let frequency = Double(passages.count { $0.terms[term] != nil })
            return log(1 + (count - frequency + 0.5) / (frequency + 0.5))
        }
        return passages.indices.map { index in
            zip(queryTerms, weights).reduce(0) { score, item in
                guard let occurrences = passages[index].terms[item.0] else { return score }
                let tf = Double(occurrences)
                return score + item.1 * tf * (k1 + 1) / (tf + k1 * (1 - b + b * lengths[index] / averageLength))
            }
        }
    }

    // MARK: Saving

    /// One note's entry, in the file `save(in:)` writes for it.
    private struct SavedNote: Codable {
        var version: Int
        var id: String
        var entry: Entry
    }

    /// The whole index in one file, as earlier versions saved it.
    struct LegacySaved: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    /// The name of the file `save(in:)` writes the note with `id` to.
    static func fileName(forID id: String) -> String {
        NoteSearchIndex.hash([id]) + ".plist"
    }

    /// Whether notes were added, changed or removed since the last `save(in:)`.
    public var hasUnsavedChanges: Bool { !unsavedIDs.isEmpty || !removedIDs.isEmpty }

    /// Writes each note added or changed since the last save to its own file in `directory`, and
    /// deletes the files of notes removed since. Notes it couldn't write are written on the next
    /// save.
    public mutating func save(in directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for id in removedIDs {
            try? fileManager.removeItem(at: directory.appending(path: Self.fileName(forID: id)))
        }
        removedIDs = []
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        for id in unsavedIDs {
            if let entry = entries[id] {
                let data = try encoder.encode(SavedNote(version: Self.formatVersion, id: id, entry: entry))
                try data.write(to: directory.appending(path: Self.fileName(forID: id)), options: .atomic)
            }
            unsavedIDs.remove(id)
        }
    }

    /// The index `save(in:)` wrote to `directory`; empty if there's none. Files it can't use, like
    /// ones from another version, are deleted, so their notes are indexed again.
    public static func load(from directory: URL) -> NoteChatIndex {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = PropertyListDecoder()
        var index = NoteChatIndex()
        for file in files where file.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: file),
                let saved = try? decoder.decode(SavedNote.self, from: data),
                saved.version == formatVersion, file.lastPathComponent == fileName(forID: saved.id)
            else {
                try? fileManager.removeItem(at: file)
                continue
            }
            index.entries[saved.id] = saved.entry
        }
        return index
    }

    /// The index an earlier version saved in one file, with every note still to `save(in:)`.
    /// Empty if it's from another format version or unreadable.
    public static func decoded(fromLegacyFile data: Data) -> NoteChatIndex {
        guard let saved = try? PropertyListDecoder().decode(LegacySaved.self, from: data),
            saved.version == formatVersion
        else { return NoteChatIndex() }
        var index = NoteChatIndex()
        index.entries = saved.entries
        index.unsavedIDs = Set(saved.entries.keys)
        return index
    }
}

extension NoteChatIndex.Passage: Codable {
    private enum CodingKeys: String, CodingKey {
        case noteURL, line, section, time, text, embedding
    }

    // Without the title, which `Entry` has; `terms` are worked out by `Entry`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        noteURL = try container.decode(URL.self, forKey: .noteURL)
        line = try container.decode(Int.self, forKey: .line)
        section = try container.decodeIfPresent(String.self, forKey: .section)
        time = try container.decodeIfPresent(String.self, forKey: .time)
        text = try container.decode(String.self, forKey: .text)
        embedding = try container.decodeIfPresent(TextEmbedding.self, forKey: .embedding)
        terms = [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(noteURL, forKey: .noteURL)
        try container.encode(line, forKey: .line)
        try container.encodeIfPresent(section, forKey: .section)
        try container.encodeIfPresent(time, forKey: .time)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(embedding, forKey: .embedding)
    }
}

extension NoteChatIndex.Entry {
    private enum CodingKeys: String, CodingKey {
        case fingerprint, title, passages, isEmbedded
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        title = try container.decode(String.self, forKey: .title)
        isEmbedded = try container.decode(Bool.self, forKey: .isEmbedded)
        passages = try container.decode([NoteChatIndex.Passage].self, forKey: .passages)
        for index in passages.indices {
            passages[index].terms = NoteChatIndex.Passage.terms(text: passages[index].text, title: title)
        }
    }
}
