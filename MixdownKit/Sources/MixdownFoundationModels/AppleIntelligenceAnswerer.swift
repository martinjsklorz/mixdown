import Foundation
import FoundationModels
import MixdownCore
import MixdownNaturalLanguage
import os

private let logger = Logger(subsystem: "app.mixdown", category: "chat")

/// Answers questions about notes with the on-device model behind Apple Intelligence, through the
/// Foundation Models framework, from the excerpts Mixdown found for the question. Nothing leaves
/// the Mac.
public struct AppleIntelligenceAnswerer: NoteAnswerer {
    /// Tokens of the context window kept free for the instructions, the chat so far, the
    /// question and the answer.
    static let reservedTokens = 1600
    static let minimumExcerptTokens = 600
    /// Earlier questions and answers handed back to the model, newest last.
    static let maxHistoryTurns = 3
    /// Of each earlier answer handed back.
    static let maxHistoryAnswerLength = 600

    public init() {}

    public var availability: SummarizerAvailability {
        SystemModelSummary.availability(for: "to chat with your notes")
    }

    public var excerptTokenBudget: Int {
        max(SystemLanguageModel.default.contextSize - Self.reservedTokens, Self.minimumExcerptTokens)
    }

    public func answer(
        _ question: String,
        excerpts: [NoteExcerpt],
        history: [ChatTurn],
        now: Date
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.answer(question, excerpts: excerpts, history: history, now: now) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func answer(
        _ question: String,
        excerpts: [NoteExcerpt],
        history: [ChatTurn],
        now: Date,
        yield: (String) -> Void
    ) async throws {
        if case .unavailable(let reason) = SystemModelSummary.availability(for: "to chat with your notes") {
            throw NoteAnswerError.unavailable(reason)
        }
        // Only if it's long enough to tell.
        let language = TranscriptLanguage.code(of: question, minimumConfidence: 0.6)
        let rules = instructions(now: now, language: language)
        var excerpts = excerpts
        while true {
            let session = SystemModelSummary.makeSession(instructions: rules)
            var hasAnswered = false
            do {
                let stream = session.streamResponse(
                    to: Prompt(prompt(question, excerpts: excerpts, history: history)),
                    options: GenerationOptions(temperature: 0.3)
                )
                for try await snapshot in stream {
                    hasAnswered = true
                    yield(snapshot.content)
                }
                return
            } catch let error where SystemModelSummary.isContextOverflow(error) && !hasAnswered && excerpts.count > 1 {
                // `estimatedTokens` guesses high, but the model's tokenizer can still disagree.
                logger.info("\(excerpts.count) excerpts overflowed the context, trying with half")
                excerpts = Array(excerpts.prefix(excerpts.count / 2))
            } catch let error as LanguageModelSession.GenerationError {
                if case .guardrailViolation = error { throw NoteAnswerError.refused }
                if case .refusal = error { throw NoteAnswerError.refused }
                throw NoteAnswerError.failed(error.localizedDescription)
            } catch {
                if #available(macOS 27, *), let error = error as? LanguageModelError {
                    switch error {
                    case .guardrailViolation, .refusal: throw NoteAnswerError.refused
                    default: break
                    }
                }
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw NoteAnswerError.failed(error.localizedDescription)
            }
        }
    }

    private static func instructions(now: Date, language: String?) -> String {
        // The model answers in the language of its input, and the excerpts may be in another one
        // than the question.
        let languageName = language.flatMap { Locale(identifier: "en").localizedString(forIdentifier: $0) }
        let languageRule =
            languageName.map { "You MUST answer in \($0)." } ?? "You MUST answer in the language of the question."
        return """
            You answer questions about the user's notes: transcripts and summaries of their meetings, \
            calls and voice memos. Today is \(formatted(now)).
            The user gives you numbered excerpts from the notes, each with its note's title and date, \
            then a question. Answer only from the excerpts; don't add anything. Right after each \
            statement, cite the excerpts it comes from by their numbers in square brackets, like [2] or \
            [1][3]. If the excerpts don't answer the question, say you couldn't find that in the notes.
            Be brief: a few sentences, or a short list. \(languageRule)
            """
    }

    private static func prompt(_ question: String, excerpts: [NoteExcerpt], history: [ChatTurn]) -> String {
        var parts: [String] = []
        let turns = history.suffix(maxHistoryTurns)
        if !turns.isEmpty {
            let lines = turns.map { turn in
                // Its citations were of other excerpts.
                let answer = ChatCitations.pieces(of: turn.answer, valid: []).map { piece in
                    if case .text(let text) = piece { text } else { "" }
                }
                .joined()
                return "Question: \(turn.question)\nAnswer: \(answer.prefix(maxHistoryAnswerLength))"
            }
            parts.append("Earlier in this chat:\n" + lines.joined(separator: "\n\n"))
        }
        let quoted = excerpts.map { excerpt in
            var source = "From “\(excerpt.noteTitle)”, \(formatted(excerpt.date))"
            if let section = excerpt.section { source += ", \(section)" }
            if let time = excerpt.time { source += " at \(time)" }
            return "[\(excerpt.number)] \(source):\n\(excerpt.text)"
        }
        parts.append("Excerpts:\n\n" + quoted.joined(separator: "\n\n"))
        parts.append("Question: \(question)")
        return parts.joined(separator: "\n\n")
    }

    /// E.g. "Wednesday, 21 October 2026".
    private static func formatted(_ date: Date) -> String {
        date.formatted(
            .dateTime.weekday(.wide).day().month(.wide).year().locale(Locale(identifier: "en_GB"))
        )
    }
}
