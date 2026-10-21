import Foundation
import FoundationModels
import MixdownCore
import NaturalLanguage
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
        let model = SystemLanguageModel.default
        if case .unavailable(let reason) = availability { throw SummarizationError.unavailable(reason) }

        // `estimatedTokens` guesses high, but the model's tokenizer can still disagree. A piece
        // that overflows the context is split again by `ChunkedSummarizer`.
        let summarizer = ChunkedSummarizer(
            maxTokens: max(model.contextSize - reservedTokens, minimumPieceTokens),
            minTokens: minimumPieceTokens
        )
        let language = languageCode(of: transcript)
        var summary = try await summarizer.summarize(transcript) { text, kind in
            do {
                return try await respond(to: text, kind: kind, template: template, model: model, language: language)
            } catch let error where isContextOverflow(error) {
                logger.info("A piece of \(text.count) characters overflowed the context")
                throw SummarizationError.tooLong
            }
        }
        summary.language = language
        return summary
    }

    /// One model call, in a fresh session so earlier pieces don't take up the context.
    private static func respond(
        to text: String,
        kind: ChunkedSummarizer.Step,
        template: SummaryTemplate,
        model: SystemLanguageModel,
        language: String?
    ) async throws -> NoteSummary {
        let rules = instructions(for: kind, template: template, language: language)
        let session: LanguageModelSession
        if #available(macOS 27, *) {
            session = makeSession(model: model, instructions: rules)
        } else {
            session = LanguageModelSession(model: model) { rules }
        }
        let prompt = kind == .transcript ? "Transcript:\n\(text)" : text
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

    /// A session with `instructions`. Generic because macOS 27 adds an initializer for any
    /// `LanguageModel` next to the one for `SystemLanguageModel`, and a `SystemLanguageModel` matches
    /// both; for a generic model only the new one does.
    @available(macOS 27, *)
    private static func makeSession<Model: LanguageModel>(model: Model, instructions: String) -> LanguageModelSession {
        LanguageModelSession(model: model) { instructions }
    }

    static func instructions(
        for kind: ChunkedSummarizer.Step,
        template: SummaryTemplate,
        language: String?
    ) -> String {
        let task =
            switch kind {
            case .transcript:
                """
                You summarize recordings such as meetings, calls and voice memos. The user gives you \
                a transcript or part of one. Lines may start with the speaker's name.
                """
            case .combine:
                """
                You summarize recordings such as meetings, calls and voice memos. The user gives you \
                summaries of consecutive parts of one recording, in order. Merge them into a single \
                summary of the whole recording, combining points that repeat and keeping every \
                decision and action item. Drop questions that a later part answers.
                """
            }
        // The model answers in the language of its input, and the instructions and the summary's
        // schema are English. Without a firm rule, a German recording gets an English overview.
        let languageName = language.flatMap { Locale(identifier: "en").localizedString(forIdentifier: $0) }
        let languageRule =
            languageName.map { "You MUST write in \($0)." } ?? "You MUST write in the language of the transcript."
        return """
            \(task)\(focus(of: template).map { "\n" + $0 } ?? "")
            Only use what's in the text; don't add anything. Be brief and concrete. \(languageRule)
            """
    }

    /// What kind of recording `template` is for, and what matters in one.
    static func focus(of template: SummaryTemplate) -> String? {
        switch template {
        case .general:
            nil
        case .oneOnOne:
            """
            The recording is a one-on-one meeting between two people, such as a manager and a team \
            member. Look out for feedback, goals, concerns and what the two agreed on.
            """
        case .standup:
            """
            The recording is a team standup. Look out for what each person finished, what they'll \
            work on next and what blocks them, naming the person.
            """
        case .clientCall:
            """
            The recording is a call with a client. Look out for the client's needs and requirements, \
            what was promised to them, and the next steps on both sides.
            """
        }
    }

    /// The language the transcript was made in, or else the one most of its text is in. Speech
    /// models that detect the language themselves don't report it.
    static func languageCode(of transcript: MixdownCore.Transcript) -> String? {
        if let language = transcript.language, !language.isEmpty { return language }
        let recognizer = NLLanguageRecognizer()
        // Plenty to tell the language from, without reading an hour of text.
        recognizer.processString(String(transcript.text.prefix(4000)))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
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
            keyPoints: keyPoints.map(Self.listItem),
            actionItems: actionItems.map(Self.listItem)
        )
    }

    /// Drops a bullet the model sometimes writes itself, since the note adds its own.
    static func listItem(_ text: String) -> String {
        var item = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for bullet in ["- ", "• ", "* "] where item.hasPrefix(bullet) {
            item = String(item.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
        }
        return item
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
            decisions: decisions.map(GeneratedSummary.listItem),
            actionItems: actionItems.map(GeneratedSummary.listItem),
            openQuestions: openQuestions.map(GeneratedSummary.listItem)
        )
    }
}
