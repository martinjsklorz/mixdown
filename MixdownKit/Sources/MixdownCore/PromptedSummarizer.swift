import Foundation
import os

/// One call to a backend's model: what `PromptedSummarizer` asks it for one piece of a recording.
public struct SummaryRequest: Sendable, Equatable {
    /// What the model is told to do, from `SummaryPrompt` or `SpeakerNaming`. A backend may add
    /// how to shape the answer.
    public var instructions: String
    /// The piece of text to work on.
    public var prompt: String
    public var kind: ChunkedSummarizer.Step

    public init(instructions: String, prompt: String, kind: ChunkedSummarizer.Step) {
        self.instructions = instructions
        self.prompt = prompt
        self.kind = kind
    }
}

/// What summarizing, catching up and naming speakers take whatever the model: the transcript in
/// pieces that fit it (see `ChunkedSummarizer` and `SpeakerNaming`), the instructions for each,
/// and the summary finished with its template, language and title. A backend only runs each
/// request, in a fresh conversation so earlier pieces don't take up the context, and checks that
/// it's available before.
public struct PromptedSummarizer: Sendable {
    private static let logger = Logger(subsystem: "app.mixdown", category: "summary")

    /// Most estimated tokens (see `ChunkedSummarizer.estimatedTokens(in:)`) of text handed to the
    /// model at once, with the instructions that vary: the template's own and what they say about
    /// marked moments.
    private let maxTokens: Int
    /// Pieces aren't made smaller than this when they're too long for the model; they're left out
    /// instead.
    private let minTokens: Int

    public init(maxTokens: Int, minTokens: Int = 1) {
        self.maxTokens = maxTokens
        self.minTokens = minTokens
    }

    /// `transcript` summarized in the shape of `template`, covering `moments`, in `language`, an
    /// ISO 639-1 code, or with `nil` in the transcript's.
    /// - Parameters:
    ///   - respond: Runs one request and reads the summary in the answer. Throws
    ///     `SummarizationError.tooLong` for text that doesn't fit the model.
    ///   - title: A title for the summary, which has its language set, for models that may leave
    ///     it out of their answer, and for a summary put together without the model (see
    ///     `ChunkedSummarizer`). Called only when the title is blank; if it fails, the title stays
    ///     blank and the note is titled with its date.
    public func summarize(
        _ transcript: Transcript,
        moments: [Moment],
        template: SummaryTemplate,
        language: String?,
        respond: (SummaryRequest) async throws -> NoteSummary,
        title: ((NoteSummary) async throws -> String)? = nil
    ) async throws -> NoteSummary {
        let hasMoments = !moments.isEmpty
        let chunked = ChunkedSummarizer(
            maxTokens: pieceTokens(template: template, hasMoments: hasMoments),
            minTokens: minTokens
        )
        var summary = try await chunked.summarize(transcript, moments: moments) { text, kind in
            let instructions = SummaryPrompt.instructions(
                for: kind,
                template: template,
                language: language,
                hasMoments: hasMoments
            )
            let prompt = SummaryPrompt.prompt(for: text, kind: kind)
            return try await respond(SummaryRequest(instructions: instructions, prompt: prompt, kind: kind))
        }
        summary.template = template
        summary.language = language
        if let title, summary.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !summary.isEmpty {
            do {
                summary.title = try await title(summary)
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                Self.logger.error("Got no title for the summary: \(error, privacy: .public)")
            }
        }
        return summary
    }

    /// What was said in `transcript`, the last few minutes of a recording under way, in at most
    /// `SummaryFields.maximumCatchUpPoints` points; see `Summarizer.catchUp(on:language:)`.
    /// - Parameter respond: Runs one request and reads the points in the answer. Throws
    ///   `SummarizationError.tooLong` for text that doesn't fit the model.
    public func catchUp(
        on transcript: Transcript,
        language: String?,
        respond: (SummaryRequest) async throws -> [String]
    ) async throws -> [String] {
        // Minutes of fast talking can still be too long for the model; they're caught up on in
        // parts, then those combined, like a long recording's summary.
        let chunked = ChunkedSummarizer(maxTokens: maxTokens, minTokens: minTokens)
        let summary = try await chunked.summarize(transcript) { text, kind in
            let request = SummaryRequest(
                instructions: SummaryPrompt.catchUpInstructions(for: kind, language: language),
                prompt: SummaryPrompt.prompt(for: text, kind: kind),
                kind: kind
            )
            return NoteSummary(keyPoints: try await respond(request))
        }
        return Array(summary.keyPoints.prefix(SummaryFields.maximumCatchUpPoints))
    }

    /// Names for `speakers` after what's said in `transcript`; see `SpeakerNaming`.
    /// - Parameter respond: Runs one request and reads the names by label in the answer.
    public func nameSpeakers(
        _ speakers: [String],
        in transcript: Transcript,
        respond: (SummaryRequest) async throws -> [String: String]
    ) async throws -> [String: String] {
        try await SpeakerNaming.names(for: speakers, in: transcript, maxTokens: maxTokens) { text, speakers in
            try await respond(
                SummaryRequest(
                    instructions: SpeakerNaming.instructions,
                    prompt: SpeakerNaming.prompt(for: text, speakers: speakers),
                    kind: .transcript
                )
            )
        }
    }

    /// Most tokens of a piece of transcript summarized with `template`: what's left of `maxTokens`
    /// after the instructions the user wrote, and what the instructions say about marked moments.
    func pieceTokens(template: SummaryTemplate, hasMoments: Bool) -> Int {
        let extraInstructions = [
            SummaryPrompt.focus(of: template),
            hasMoments ? SummaryPrompt.momentsRule(for: .transcript) : nil,
        ]
        let instructionTokens = extraInstructions.compactMap { $0 }.reduce(0) {
            $0 + ChunkedSummarizer.estimatedTokens(in: $1)
        }
        return max(maxTokens - instructionTokens, minTokens)
    }
}
