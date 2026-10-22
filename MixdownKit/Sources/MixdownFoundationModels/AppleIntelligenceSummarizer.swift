import Foundation
import FoundationModels
import MixdownCore
import MixdownNaturalLanguage
import os

private let logger = Logger(subsystem: "app.mixdown", category: "summary")

/// Summarizes with the on-device model behind Apple Intelligence, through the Foundation Models
/// framework. Nothing is downloaded by Mixdown and nothing leaves the Mac.
///
/// Needs Apple Intelligence turned on; `availability` says what's missing.
public struct AppleIntelligenceSummarizer: Summarizer {
    public let info = SummarizerInfo(id: "apple-intelligence", displayName: "Apple Intelligence")

    public init() {}

    public var availability: SummarizerAvailability {
        SystemModelSummary.availability
    }

    // Qualified because FoundationModels has a `Transcript` of its own.
    public func summarize(_ transcript: MixdownCore.Transcript, template: SummaryTemplate) async throws -> NoteSummary {
        try await SystemModelSummary.summarize(transcript, template: template)
    }

    public func catchUp(on transcript: MixdownCore.Transcript, language: String?) async throws -> [String] {
        try await SystemModelSummary.catchUp(on: transcript, language: language)
    }
}

enum SystemModelSummary {
    /// Tokens of the context window kept free for the instructions, the response schema and the
    /// response.
    static let reservedTokens = 1100
    /// Pieces aren't made smaller than this when the context overflows; they're left out of the
    /// summary instead.
    static let minimumPieceTokens = 400

    static var availability: SummarizerAvailability {
        availability(for: "to get summaries")
    }

    /// Whether the model can be used, and if not, why; `purpose` finishes the sentence about
    /// turning Apple Intelligence on, e.g. "to get summaries".
    static func availability(for purpose: String) -> SummarizerAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(reason: "This Mac doesn't support Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .unavailable(reason: "Turn on Apple Intelligence in System Settings \(purpose).")
            case .modelNotReady:
                return .unavailable(reason: "Apple Intelligence is still getting ready. Try again later.")
            @unknown default:
                return .unavailable(reason: "Apple Intelligence isn't available right now.")
            }
        }
    }

    static func summarize(_ transcript: MixdownCore.Transcript, template: SummaryTemplate) async throws -> NoteSummary {
        let language = TranscriptLanguage.code(of: transcript)
        var summary = try await summarizeInPieces(transcript) { text, kind in
            try await respond(to: text, kind: kind, template: template, language: language)
        }
        summary.language = language
        return summary
    }

    /// What was said in the last few minutes of a recording under way, in a few points, for
    /// someone who drifted off. Runs on the Mac like the summaries, so it costs nothing and
    /// nothing is sent anywhere.
    static func catchUp(on transcript: MixdownCore.Transcript, language: String?) async throws -> [String] {
        let language = language ?? TranscriptLanguage.code(of: transcript)
        // Minutes of fast talking can still overflow the context; they're caught up on in parts,
        // then those combined, like a long recording's summary.
        let summary = try await summarizeInPieces(transcript) { text, kind in
            NoteSummary(keyPoints: try await catchUpPoints(for: text, kind: kind, language: language))
        }
        return summary.keyPoints
    }

    /// `transcript` summarized by `ChunkedSummarizer`, in pieces that fit the model's context.
    /// Throws `SummarizationError.unavailable` if the model can't be used.
    ///
    /// `estimatedTokens` guesses high, but the model's tokenizer can still disagree. A piece that
    /// overflows the context is split again.
    private static func summarizeInPieces(
        _ transcript: MixdownCore.Transcript,
        step: (_ text: String, _ kind: ChunkedSummarizer.Step) async throws -> NoteSummary
    ) async throws -> NoteSummary {
        if case .unavailable(let reason) = availability { throw SummarizationError.unavailable(reason) }
        let summarizer = ChunkedSummarizer(
            maxTokens: max(SystemLanguageModel.default.contextSize - reservedTokens, minimumPieceTokens),
            minTokens: minimumPieceTokens
        )
        return try await summarizer.summarize(transcript) { text, kind in
            do {
                return try await step(text, kind)
            } catch let error where isContextOverflow(error) {
                logger.info("A piece of \(text.count) characters overflowed the context")
                throw SummarizationError.tooLong
            }
        }
    }

    /// One model call, in a fresh session so earlier pieces don't take up the context.
    private static func respond(
        to text: String,
        kind: ChunkedSummarizer.Step,
        template: SummaryTemplate,
        language: String?
    ) async throws -> NoteSummary {
        let rules = SummaryPrompt.instructions(for: kind, template: template, language: language)
        let session = makeSession(instructions: rules)
        let prompt = SummaryPrompt.prompt(for: text, kind: kind)
        // The explicit `includeSchemaInPrompt` picks the macOS 26 overload over macOS 27's
        // metadata one, whose other parameters have defaults too.
        guard template.hasFixedSections else {
            let response = try await session.respond(generating: GeneratedSummary.self, includeSchemaInPrompt: true) {
                prompt
            }
            return response.content.noteSummary
        }
        let response = try await session.respond(
            generating: GeneratedSectionedSummary.self,
            includeSchemaInPrompt: true
        ) {
            prompt
        }
        return response.content.noteSummary(template: template)
    }

    /// One catch-up call, in a fresh session.
    private static func catchUpPoints(
        for text: String,
        kind: ChunkedSummarizer.Step,
        language: String?
    ) async throws -> [String] {
        let session = makeSession(instructions: SummaryPrompt.catchUpInstructions(for: kind, language: language))
        let prompt = SummaryPrompt.prompt(for: text, kind: kind)
        // See `respond(to:kind:template:language:)`.
        let response = try await session.respond(generating: GeneratedCatchUp.self, includeSchemaInPrompt: true) {
            prompt
        }
        return response.content.points.map(SummaryPrompt.listItem)
    }

    /// A new session with the system model and `instructions`.
    static func makeSession(instructions: String) -> LanguageModelSession {
        if #available(macOS 27, *) {
            return makeSession(model: SystemLanguageModel.default, instructions: instructions)
        }
        return LanguageModelSession(model: .default) { instructions }
    }

    /// A session with `instructions`. Generic because macOS 27 adds an initializer for any
    /// `LanguageModel` next to the one for `SystemLanguageModel`, and a `SystemLanguageModel` matches
    /// both; for a generic model only the new one does.
    @available(macOS 27, *)
    private static func makeSession<Model: LanguageModel>(model: Model, instructions: String) -> LanguageModelSession {
        LanguageModelSession(model: model) { instructions }
    }

    static func isContextOverflow(_ error: any Error) -> Bool {
        if case LanguageModelSession.GenerationError.exceededContextWindowSize = error { return true }
        if #available(macOS 27, *), case LanguageModelError.contextSizeExceeded = error { return true }
        return false
    }
}

@Generable
struct GeneratedSummary {
    // Generated in this order, so the overview and the title can draw on what comes before them.
    @Guide(
        description: "The most important points, decisions and conclusions, one short sentence each",
        .maximumCount(8)
    )
    var keyPoints: [String]

    @Guide(
        description: "Tasks someone agreed to do, naming who if the text says. Empty if there are none",
        .maximumCount(8)
    )
    var actionItems: [String]

    @Guide(description: "Two to four sentences on what the recording is about")
    var overview: String

    @Guide(description: "The topic in two to six words, as a title. Not a sentence; no \"Meeting about\" or similar")
    var title: String

    var noteSummary: NoteSummary {
        NoteSummary(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            overview: overview.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: keyPoints.map(SummaryPrompt.listItem),
            actionItems: actionItems.map(SummaryPrompt.listItem)
        )
    }

}

/// A summary in the fixed sections of every template but `general`.
@Generable
struct GeneratedSectionedSummary {
    // Generated in this order, so the TL;DR and the title can draw on what comes before them.
    @Guide(description: "Decisions that were made, one short sentence each. Empty if there are none", .maximumCount(8))
    var decisions: [String]

    @Guide(
        description: "Tasks someone agreed to do, naming who if the text says. Empty if there are none",
        .maximumCount(8)
    )
    var actionItems: [String]

    @Guide(
        description: "Questions that were raised but not answered, one each. Empty if there are none",
        .maximumCount(8)
    )
    var openQuestions: [String]

    @Guide(description: "TL;DR: one to three sentences on what the recording is about and its outcome")
    var tldr: String

    @Guide(description: "The topic in two to six words, as a title. Not a sentence; no \"Meeting about\" or similar")
    var title: String

    func noteSummary(template: SummaryTemplate) -> NoteSummary {
        NoteSummary(
            template: template,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            overview: tldr.trimmingCharacters(in: .whitespacesAndNewlines),
            decisions: decisions.map(SummaryPrompt.listItem),
            actionItems: actionItems.map(SummaryPrompt.listItem),
            openQuestions: openQuestions.map(SummaryPrompt.listItem)
        )
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
