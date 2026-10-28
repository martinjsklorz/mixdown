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
    public func summarize(
        _ transcript: MixdownCore.Transcript,
        moments: [Moment],
        template: SummaryTemplate
    ) async throws -> NoteSummary {
        try await SystemModelSummary.summarize(transcript, moments: moments, template: template)
    }

    public func catchUp(on transcript: MixdownCore.Transcript, language: String?) async throws -> [String] {
        try await SystemModelSummary.catchUp(on: transcript, language: language)
    }

    public func nameSpeakers(
        _ speakers: [String],
        in transcript: MixdownCore.Transcript
    ) async throws -> [String: String] {
        try await SystemModelSummary.nameSpeakers(speakers, in: transcript)
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

    static func summarize(
        _ transcript: MixdownCore.Transcript,
        moments: [Moment],
        template: SummaryTemplate
    ) async throws -> NoteSummary {
        try await prompted().summarize(
            transcript,
            moments: moments,
            template: template,
            language: TranscriptLanguage.code(of: transcript)
        ) { request in
            try await overflowAsTooLong(request) { try await respond(to: request, template: template) }
        } title: { summary in
            // The schema always has a title, but parts merged without the model don't.
            let session = makeSession(instructions: SummaryPrompt.titleInstructions(language: summary.language))
            return SummaryPrompt.title(from: try await session.respond(to: summary.plainText).content)
        }
    }

    /// What was said in the last few minutes of a recording under way, in a few points, for
    /// someone who drifted off. Runs on the Mac like the summaries, so it costs nothing and
    /// nothing is sent anywhere.
    static func catchUp(on transcript: MixdownCore.Transcript, language: String?) async throws -> [String] {
        try await prompted().catchUp(on: transcript, language: language ?? TranscriptLanguage.code(of: transcript)) {
            request in
            try await overflowAsTooLong(request) { try await catchUpPoints(for: request) }
        }
    }

    /// Splits transcripts in pieces that fit the model's context. Throws
    /// `SummarizationError.unavailable` if the model can't be used.
    private static func prompted() throws -> PromptedSummarizer {
        if case .unavailable(let reason) = availability { throw SummarizationError.unavailable(reason) }
        return PromptedSummarizer(
            maxTokens: max(SystemLanguageModel.default.contextSize - reservedTokens, minimumPieceTokens),
            minTokens: minimumPieceTokens
        )
    }

    /// What `call` returns for `request`, with a context overflow thrown as
    /// `SummarizationError.tooLong`: `estimatedTokens` guesses high, but the model's tokenizer can
    /// still disagree, and the piece is split again.
    private static func overflowAsTooLong<Value>(
        _ request: SummaryRequest,
        _ call: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await call()
        } catch let error where isContextOverflow(error) {
            logger.info("A piece of \(request.prompt.count) characters overflowed the context")
            throw SummarizationError.tooLong
        }
    }

    /// One model call, in a fresh session so earlier pieces don't take up the context.
    private static func respond(to request: SummaryRequest, template: SummaryTemplate) async throws -> NoteSummary {
        let session = makeSession(instructions: request.instructions)
        let prompt = request.prompt
        // The explicit `includeSchemaInPrompt` picks the macOS 26 overload over macOS 27's
        // metadata one, whose other parameters have defaults too.
        guard template.hasFixedSections else {
            let response = try await session.respond(generating: GeneratedSummary.self, includeSchemaInPrompt: true) {
                prompt
            }
            return response.content.noteSummary(template: template)
        }
        let response = try await session.respond(
            generating: GeneratedSectionedSummary.self,
            includeSchemaInPrompt: true
        ) {
            prompt
        }
        return response.content.noteSummary
    }

    /// Names for `speakers` after what's said in `transcript`; see `SpeakerNaming`. A piece that
    /// overflows the context is left out.
    static func nameSpeakers(
        _ speakers: [String],
        in transcript: MixdownCore.Transcript
    ) async throws -> [String: String] {
        try await prompted().nameSpeakers(speakers, in: transcript) { request in
            let session = makeSession(instructions: request.instructions)
            let prompt = request.prompt
            // See `respond(to:template:)`.
            let response = try await session.respond(
                generating: GeneratedSpeakerNames.self,
                includeSchemaInPrompt: true
            ) {
                prompt
            }
            return response.content.guesses
        }
    }

    /// One catch-up call, in a fresh session.
    private static func catchUpPoints(for request: SummaryRequest) async throws -> [String] {
        let session = makeSession(instructions: request.instructions)
        let prompt = request.prompt
        // See `respond(to:template:)`.
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

// The descriptions and limits are `SummaryFields`', which `JSONSummary` tells other models too.

@Generable
struct GeneratedSummary {
    // Generated in this order, so the overview and the title can draw on what comes before them.
    @Guide(description: SummaryFields.keyPoints, .maximumCount(SummaryFields.maximumItems))
    var keyPoints: [String]

    @Guide(description: SummaryFields.actionItems, .maximumCount(SummaryFields.maximumItems))
    var actionItems: [String]

    @Guide(description: SummaryFields.overview)
    var overview: String

    @Guide(description: SummaryFields.title)
    var title: String

    func noteSummary(template: SummaryTemplate) -> NoteSummary {
        NoteSummary(
            template: template,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            overview: overview.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: keyPoints.map(SummaryPrompt.listItem),
            actionItems: actionItems.map(SummaryPrompt.listItem)
        )
    }

}

/// A summary in the fixed sections of templates with the `sections` layout.
@Generable
struct GeneratedSectionedSummary {
    // Generated in this order, so the TL;DR and the title can draw on what comes before them.
    @Guide(description: SummaryFields.decisions, .maximumCount(SummaryFields.maximumItems))
    var decisions: [String]

    @Guide(description: SummaryFields.actionItems, .maximumCount(SummaryFields.maximumItems))
    var actionItems: [String]

    @Guide(description: SummaryFields.openQuestions, .maximumCount(SummaryFields.maximumItems))
    var openQuestions: [String]

    @Guide(description: SummaryFields.tldr)
    var tldr: String

    @Guide(description: SummaryFields.title)
    var title: String

    /// Without its template, which `PromptedSummarizer` sets.
    var noteSummary: NoteSummary {
        NoteSummary(
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
    @Guide(description: SummaryFields.catchUpPoints, .maximumCount(SummaryFields.maximumCatchUpPoints))
    var points: [String]
}

@Generable
struct GeneratedSpeakerNames {
    @Guide(description: "Only the labels whose speaker the transcript makes clear; empty if there are none")
    var speakers: [GeneratedSpeakerName]

    /// Names by label; the first for a label asked about twice.
    var guesses: [String: String] {
        Dictionary(speakers.map { ($0.label, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}

@Generable
struct GeneratedSpeakerName {
    @Guide(description: "The label exactly as asked about, such as \"Speaker 2\"")
    var label: String

    @Guide(description: "The speaker's name, written as in the transcript")
    var name: String
}
