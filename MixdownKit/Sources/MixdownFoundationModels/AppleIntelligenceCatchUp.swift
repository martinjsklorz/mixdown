import Foundation
import FoundationModels
import MixdownCore
import os

private let logger = Logger(subsystem: "app.mixdown", category: "summary")

extension AppleIntelligenceSummarizer {
    public func catchUp(on transcript: MixdownCore.Transcript, language: String?) async throws -> [String] {
        try await SystemModelCatchUp.catchUp(on: transcript, language: language)
    }
}

/// What was said in the last few minutes of a recording under way, in a few points, for someone
/// who drifted off. Runs on the Mac like the summaries, so it costs nothing and nothing is sent
/// anywhere.
enum SystemModelCatchUp {
    static func catchUp(on transcript: MixdownCore.Transcript, language: String?) async throws -> [String] {
        let model = SystemLanguageModel.default
        if case .unavailable(let reason) = SystemModelSummary.availability {
            throw SummarizationError.unavailable(reason)
        }
        // Minutes of fast talking can still overflow the context; they're caught up on in parts,
        // then those combined, like a long recording's summary.
        let summarizer = ChunkedSummarizer(
            maxTokens: max(
                model.contextSize - SystemModelSummary.reservedTokens,
                SystemModelSummary.minimumPieceTokens
            ),
            minTokens: SystemModelSummary.minimumPieceTokens
        )
        let language = language ?? SystemModelSummary.languageCode(of: transcript)
        let summary = try await summarizer.summarize(transcript) { text, kind in
            do {
                return NoteSummary(keyPoints: try await respond(to: text, kind: kind, model: model, language: language))
            } catch let error where SystemModelSummary.isContextOverflow(error) {
                logger.info("A piece of \(text.count) characters overflowed the context")
                throw SummarizationError.tooLong
            }
        }
        return summary.keyPoints
    }

    /// One model call, in a fresh session.
    private static func respond(
        to text: String,
        kind: ChunkedSummarizer.Step,
        model: SystemLanguageModel,
        language: String?
    ) async throws -> [String] {
        let rules = instructions(for: kind, language: language)
        let session: LanguageModelSession
        if #available(macOS 27, *) {
            session = makeSession(model: model, instructions: rules)
        } else {
            session = LanguageModelSession(model: model) { rules }
        }
        let prompt = kind == .transcript ? "Transcript:\n\(text)" : text
        // See `SystemModelSummary.respond`.
        let response = try await session.respond(generating: GeneratedCatchUp.self, includeSchemaInPrompt: true) {
            prompt
        }
        return response.content.points.map(GeneratedSummary.listItem)
    }

    /// See `SystemModelSummary.makeSession(model:instructions:)`.
    @available(macOS 27, *)
    private static func makeSession<Model: LanguageModel>(model: Model, instructions: String) -> LanguageModelSession {
        LanguageModelSession(model: model) { instructions }
    }

    static func instructions(for kind: ChunkedSummarizer.Step, language: String?) -> String {
        let task =
            switch kind {
            case .transcript:
                """
                Someone in a meeting or call that's still going on lost focus for a few minutes. The \
                user gives you the transcript of those minutes. Lines may start with the speaker's \
                name. Tell them what they missed, so they can follow again: the topics, what was \
                decided, and anything they were asked or that's expected of them.
                """
            case .combine:
                """
                Someone in a meeting or call that's still going on lost focus for a few minutes. The \
                user gives you short notes on consecutive parts of those minutes, in order. Merge \
                them into one short list of what they missed, combining points that repeat.
                """
            }
        // As in `SystemModelSummary.instructions`: without a firm rule, the model answers in the
        // language of its input, which isn't the one asked for when the live text is translated.
        let languageName = language.flatMap { Locale(identifier: "en").localizedString(forIdentifier: $0) }
        let languageRule =
            languageName.map { "You MUST write in \($0)." } ?? "You MUST write in the language of the transcript."
        return """
            \(task)
            Only use what's in the text; don't add anything. Keep to what matters most, oldest first. \
            Be brief and concrete. \(languageRule)
            """
    }
}

@Generable
struct GeneratedCatchUp {
    @Guide(
        description: "What was missed, oldest first, one short sentence each, naming who said what where it matters",
        .maximumCount(4)
    )
    var points: [String]
}
