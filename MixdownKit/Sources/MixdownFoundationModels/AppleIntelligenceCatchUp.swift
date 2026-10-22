import Foundation
import FoundationModels
import MixdownCore
import MixdownNaturalLanguage
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
        let language = language ?? TranscriptLanguage.code(of: transcript)
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
        let rules = SummaryPrompt.catchUpInstructions(for: kind, language: language)
        let session: LanguageModelSession
        if #available(macOS 27, *) {
            session = makeSession(model: model, instructions: rules)
        } else {
            session = LanguageModelSession(model: model) { rules }
        }
        let prompt = SummaryPrompt.prompt(for: text, kind: kind)
        // See `SystemModelSummary.respond`.
        let response = try await session.respond(generating: GeneratedCatchUp.self, includeSchemaInPrompt: true) {
            prompt
        }
        return response.content.points.map(SummaryPrompt.listItem)
    }

    /// See `SystemModelSummary.makeSession(model:instructions:)`.
    @available(macOS 27, *)
    private static func makeSession<Model: LanguageModel>(model: Model, instructions: String) -> LanguageModelSession {
        LanguageModelSession(model: model) { instructions }
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
