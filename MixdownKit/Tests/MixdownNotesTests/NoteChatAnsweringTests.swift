import Foundation
import MixdownCore
import Testing

@testable import MixdownNotes

@MainActor
struct NoteChatAnsweringTests {
    private static let releaseNotes = (1...7).map { number in
        note("Release \(number)", body: "## Summary\n\nThe release \(number) moves to Friday.")
    }
    private static let budget = note("Budget", body: "## Summary\n\nWe need more money for the team.")

    private static func note(_ name: String, body: String) -> NoteDocument {
        NoteDocument(
            url: URL(filePath: "/notes/\(name).md"),
            contents: "---\ntitle: \"\(name)\"\n---\n\n\(body)",
            fileDate: .distantPast
        )
    }

    /// A chat of `notes`, read beforehand so it can answer right away.
    private func makeChat(
        _ answerer: FakeAnswerer,
        embedder: GatedEmbedder = GatedEmbedder(),
        notes: [NoteDocument] = Self.releaseNotes + [Self.budget]
    ) async throws -> NoteChat {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NoteChatAnsweringTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        var index = NoteChatIndex()
        try await index.update(to: notes, embedder: embedder)
        try index.save(in: directory)
        let chat = NoteChat(answerer: answerer, embedder: embedder, indexDirectory: directory)
        chat.update(notes: notes)
        return chat
    }

    private func ask(_ question: String, in chat: NoteChat) async throws {
        chat.ask(question)
        try await waitUntil { !chat.isAnswering }
    }

    // MARK: Answering

    @Test func answersFromTheMatchingLines() async throws {
        let answerer = FakeAnswerer()
        let chat = try await makeChat(answerer)

        try await ask("When does the release ship?", in: chat)

        let excerpts = try #require(answerer.calls.first?.excerpts)
        #expect(excerpts.count == 7)
        #expect(excerpts.allSatisfy { $0.text.contains("release") })
        #expect(excerpts.map(\.number) == Array(1...7))
        #expect(chat.messages.last?.text == "An answer [1].")
        #expect(chat.messages.last?.sources.map(\.number) == Array(1...7))
        #expect(chat.messages.last?.isWriting == false)
    }

    @Test func excerptsStopAtTheTokenBudget() async throws {
        let answerer = FakeAnswerer(excerptTokenBudget: 1)
        let chat = try await makeChat(answerer)

        try await ask("When does the release ship?", in: chat)

        // Always at least one, even if it doesn't fit.
        #expect(answerer.calls.first?.excerpts.count == 1)
    }

    @Test func countsQuestionsForACount() async throws {
        let answerer = FakeAnswerer()
        let chat = try await makeChat(answerer)

        try await ask("How many notes mention the release?", in: chat)

        let answer = try #require(chat.messages.last)
        #expect(answerer.calls.isEmpty)
        #expect(answer.sources.map(\.noteTitle) == Self.releaseNotes.map(\.title))
        #expect(answer.showsAllSources)
        #expect(answer.footnote != nil)
    }

    @Test func showsTheBestLinesWithoutAppleIntelligence() async throws {
        let answerer = FakeAnswerer()
        answerer.availability = .unavailable(reason: "Turn it on.")
        let chat = try await makeChat(answerer)

        try await ask("When does the release ship?", in: chat)

        let answer = try #require(chat.messages.last)
        #expect(answerer.calls.isEmpty)
        #expect(answer.text.contains("Turn it on."))
        #expect(answer.sources.count == NoteChat.fallbackSourceCount)
        #expect(answer.showsAllSources)
    }

    // MARK: Follow-ups

    @Test func shortFollowUpSearchesWithTheQuestionBefore() async throws {
        let answerer = FakeAnswerer()
        let chat = try await makeChat(answerer)

        try await ask("When does the release ship?", in: chat)
        try await ask("And what about Ben?", in: chat)

        #expect(answerer.calls.count == 2)
        #expect(answerer.calls.last?.excerpts.isEmpty == false)
        #expect(
            answerer.calls.last?.history == [
                ChatTurn(question: "When does the release ship?", answer: "An answer [1].")
            ]
        )
    }

    @Test func historyLeavesOutNonAnswers() async throws {
        let answerer = FakeAnswerer()
        let chat = try await makeChat(answerer)

        try await ask("And what about Ben?", in: chat)
        #expect(chat.messages.last?.text == "I couldn’t find anything about that in your notes.")
        answerer.availability = .unavailable(reason: "Turn it on.")
        try await ask("When does the release ship?", in: chat)
        answerer.availability = .available
        try await ask("When does the release ship this time?", in: chat)

        #expect(answerer.calls.count == 1)
        #expect(answerer.calls.first?.history == [])
    }

    // MARK: Stopping

    @Test func clearingThenAskingKeepsAnswering() async throws {
        let answerer = FakeAnswerer(reply: nil)
        let chat = try await makeChat(answerer)

        chat.ask("When does the release ship?")
        try await waitUntil { answerer.calls.count == 1 }
        chat.clear()
        chat.ask("Where is the budget?")
        try await waitUntil { answerer.calls.count == 2 && answerer.endedCount == 1 }
        // Long enough for the cleared answer to wind down.
        try await Task.sleep(for: .milliseconds(50))

        #expect(chat.isAnswering)
        answerer.finishAnswers(with: "Done [1].")
        try await waitUntil { !chat.isAnswering }
        #expect(chat.messages.map(\.text) == ["Where is the budget?", "Done [1]."])
    }

    @Test func stoppingWhileSearchingDoesNotAnswer() async throws {
        let answerer = FakeAnswerer()
        let gate = Gate()
        let chat = try await makeChat(answerer, embedder: GatedEmbedder(embedsPassages: true, gate: gate))

        chat.ask("When does the release ship?")
        try await waitUntil { gate.waitingCount == 1 }
        chat.stopAnswering()
        gate.open()
        try await waitUntil { !chat.isAnswering }

        #expect(answerer.calls.isEmpty)
        #expect(chat.messages.last?.isWriting == false)
        #expect(chat.turns.isEmpty)
    }
}
