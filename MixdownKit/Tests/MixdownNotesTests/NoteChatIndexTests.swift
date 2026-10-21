import Foundation
import MixdownCore
import Testing

@testable import MixdownNotes

/// Embeds text as how often it has each of a few words, so tests can tell what's similar.
private struct WordEmbedder: TextEmbedder {
    static let words = ["release", "friday", "budget", "money", "lunch"]
    struct Failure: Error {}

    var fails = false

    func embed(_ texts: [String]) async throws -> [TextEmbedding?] {
        if fails { throw Failure() }
        return texts.map(Self.embedding)
    }

    func embed(_ text: String, model: String) async throws -> TextEmbedding? {
        Self.embedding(text)
    }

    static func embedding(_ text: String) -> TextEmbedding? {
        let lowercased = text.lowercased()
        // "money" means "budget": a synonym the words alone wouldn't find.
        var vector = words.map { Float(lowercased.components(separatedBy: $0).count - 1) }
        vector[2] += vector[3]
        vector[3] = 0
        return vector.allSatisfy { $0 == 0 } ? nil : TextEmbedding(model: "words", vector: vector)
    }
}

struct NoteChatIndexTests {
    private func note(_ name: String, body: String, created: Date = .distantPast) -> NoteDocument {
        NoteDocument(
            url: URL(filePath: "/notes/\(name).md"),
            contents: "---\ntitle: \"\(name)\"\n---\n\n\(body)",
            fileDate: created
        )
    }

    private static let sync = """
        ## Summary

        We moved the release.

        ## Transcript

        **[00:00:00] Me:** Morning.

        **[00:00:05] Others:** The release moves to Friday.

        **[00:01:00] Me:** Great.

        **[00:02:00] Others:** Lunch?
        """

    // MARK: Passages

    @Test func groupsLinesOfASection() {
        let passages = NoteChatIndex.passages(of: note("Sync", body: Self.sync))

        #expect(
            passages.map(\.text) == [
                "We moved the release.", "Me: Morning.\nOthers: The release moves to Friday.\nMe: Great.",
                "Others: Lunch?",
            ]
        )
        #expect(passages.map(\.line) == [0, 1, 4])
        #expect(passages.map(\.time) == [nil, "00:00:00", "00:02:00"])
        #expect(passages.map(\.section) == ["Summary", "Transcript", "Transcript"])
    }

    @Test func splitsLongLines() {
        let words = (1...170).map { "w\($0)" }
        let passages = NoteChatIndex.passages(of: note("Long", body: "Short.\n\n" + words.joined(separator: " ")))

        #expect(passages.map { $0.text.split(separator: " ").count } == [1, 80, 80, 10])
        #expect(passages.map(\.line) == [0, 1, 1, 1])
    }

    // MARK: Updating

    @Test func embedsOnlyChangedNotes() async throws {
        var index = NoteChatIndex()
        let first = note("Sync", body: Self.sync)
        let second = note("Budget", body: "We need more money.")
        try await index.update(to: [first, second], embedder: WordEmbedder())

        #expect(index.notesToIndex([first, second], canEmbed: true).isEmpty)
        let changed = note("Budget", body: "We need less money.")
        #expect(index.notesToIndex([first, changed, changed], canEmbed: true) == [changed])

        var reports: [Int] = []
        try await index.update(to: [changed], embedder: WordEmbedder()) { done, total in reports.append(total) }
        #expect(reports == [1])
        #expect(index.entries.keys.sorted() == [changed.url.absoluteString])
        #expect(index.embeddingModels == ["words"])
    }

    @Test func notesTheEmbedderFailedForAreEmbeddedLater() async throws {
        var index = NoteChatIndex()
        let sync = note("Sync", body: Self.sync)
        try await index.update(to: [sync], embedder: WordEmbedder(fails: true))

        #expect(index.entries.values.first?.isEmbedded == false)
        #expect(index.notesToIndex([sync], canEmbed: false).isEmpty)
        #expect(index.notesToIndex([sync], canEmbed: true) == [sync])
        try await index.update(to: [sync], embedder: WordEmbedder())
        #expect(index.entries.values.first?.isEmbedded == true)
    }

    @Test func savesAndLoads() async throws {
        var index = NoteChatIndex()
        try await index.update(to: [note("Sync", body: Self.sync)], embedder: WordEmbedder())

        let loaded = NoteChatIndex.decoded(from: try index.encoded())

        #expect(loaded.entries.values.first?.passages == index.entries.values.first?.passages)
        #expect(NoteChatIndex.decoded(from: Data("junk".utf8)).isEmpty)
    }

    // MARK: Searching

    @Test func findsByWords() async throws {
        var index = NoteChatIndex()
        let notes = [note("Sync", body: Self.sync), note("Budget", body: "We need more money for the team.")]
        try await index.update(to: notes, embedder: nil)

        let results = index.search("When does the release ship?", queryEmbeddings: [], in: notes, limit: 5)

        #expect(results.first?.text == "We moved the release.")
        #expect(results.allSatisfy { $0.noteURL == notes[0].url })
    }

    @Test func findsByMeaning() async throws {
        var index = NoteChatIndex()
        let notes = [note("Sync", body: Self.sync), note("Planning", body: "We need more money for the team.")]
        try await index.update(to: notes, embedder: WordEmbedder())
        let query = "What about the budget?"

        let results = index.search(query, queryEmbeddings: [WordEmbedder.embedding(query)!], in: notes, limit: 1)

        #expect(results.map(\.text) == ["We need more money for the team."])
    }

    @Test func searchesOnlyGivenNotes() async throws {
        var index = NoteChatIndex()
        let notes = [note("Sync", body: Self.sync), note("Other", body: "The release slipped.")]
        try await index.update(to: notes, embedder: nil)

        let results = index.search("release", queryEmbeddings: [], in: [notes[1]], limit: 5)

        #expect(results.map(\.text) == ["The release slipped."])
    }

    @Test func questionWithoutWordsGetsSummariesOfNewestNotes() async throws {
        var index = NoteChatIndex()
        let notes = [note("Sync", body: Self.sync), note("Memo", body: "Remember the milk.")]
        try await index.update(to: notes, embedder: nil)

        let results = index.search("What happened?", queryEmbeddings: [], in: notes, limit: 5)

        #expect(results.map(\.text) == ["We moved the release.", "Remember the milk."])
    }

    @Test func capsPassagesPerNote() async throws {
        var index = NoteChatIndex()
        let body = (1...10).map { "**[00:00:0\($0 % 10)] Me:** Release \($0).\n\nSomething else \($0)." }
        let notes = [note("Sync", body: "## Transcript\n\n" + body.joined(separator: "\n\n"))]
        try await index.update(to: notes, embedder: nil)

        #expect(index.search("release", queryEmbeddings: [], in: notes, limit: 10, perNote: 2).count == 2)
    }

    // MARK: Words

    @Test func termsAreFoldedAndSingular() {
        #expect(NoteChatText.terms(in: "The Releases' Zürich-Plan, Anna's") == ["release", "zurich", "plan", "anna"])
    }
}
