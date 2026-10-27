import Foundation
import MixdownCore
import MixdownNaturalLanguage
import Synchronization
import os

let summaryLogger = Logger(subsystem: "app.mixdown", category: "summary")

/// Summarizes with an open language model such as Qwen3, run on this Mac with
/// [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm). The model is downloaded once from
/// Hugging Face; transcripts never leave the Mac.
///
/// Unlike Apple's model, these have no structured output, so they're asked for JSON and the
/// answer is read leniently (see `JSONSummary`). A piece whose answer holds no JSON is left out of
/// the summary, like one that fails.
public final class MLXSummarizer: Summarizer {
    public let info: SummarizerInfo
    public let model: MLXLanguageModel

    private let runtime: LanguageModelRuntime
    /// Whether the model is on disk, checked when created and after `download` and `deleteModel`,
    /// so `availability` doesn't touch the disk.
    private let downloaded: Mutex<Bool>

    /// Most estimated tokens (see `ChunkedSummarizer.estimatedTokens(in:)`) of text handed to the
    /// model at once. The models' context windows are far larger, but their cache grows with the
    /// text, to about 1 GB for this much with the 4B and 8B models, and long text is slow to read.
    /// Longer recordings are summarized in pieces.
    static let pieceTokens = 8000
    /// Most tokens of one answer. A summary of eight points per list takes well under half.
    static let maximumAnswerTokens = 1500
    /// Most tokens of an answer naming speakers: a few labels and names.
    static let maximumNamesTokens = 300

    public init(model: MLXLanguageModel) {
        self.model = model
        self.info = SummarizerInfo(id: "mlx-\(model.rawValue)", displayName: model.displayName)
        self.runtime = LanguageModelRuntime(model: model)
        self.downloaded = Mutex(ModelFiles.isComplete(model))
    }

    public var availability: SummarizerAvailability {
        guard downloaded.withLock({ $0 }) else {
            return .unavailable(reason: "Download \(model.displayName) in Settings › Summary to get summaries.")
        }
        return .available
    }

    /// Whether the model is on disk, so summaries don't need a download.
    public var isDownloaded: Bool { downloaded.withLock { $0 } }

    /// Whether `model` is on disk. Checks files only; it doesn't validate them.
    public static func isDownloaded(_ model: MLXLanguageModel) -> Bool {
        ModelFiles.isComplete(model)
    }

    /// Downloads the model, or what's missing of it. Cancelling stops the download; files already
    /// on disk are kept, so the next call resumes from them.
    /// - Parameter progress: 0...1; may be called from any thread.
    public func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            _ = try await ModelFiles.download(model, progress: progress)
            summaryLogger.info("Downloaded \(self.model.displayName, privacy: .public)")
        } catch {
            downloaded.withLock { $0 = ModelFiles.isComplete(model) }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            summaryLogger.error(
                "Downloading \(self.model.displayName, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
            throw error
        }
        downloaded.withLock { $0 = ModelFiles.isComplete(model) }
    }

    /// Unloads the model and removes its files.
    public func deleteModel() async throws {
        await runtime.unload()
        defer { downloaded.withLock { $0 = ModelFiles.isComplete(model) } }
        try ModelFiles.delete(model)
        summaryLogger.info("Deleted \(self.model.displayName, privacy: .public)")
    }

    public func summarize(
        _ transcript: Transcript,
        moments: [Moment],
        template: SummaryTemplate
    ) async throws -> NoteSummary {
        let prompted = try self.prompted()
        let language = TranscriptLanguage.code(of: transcript)
        return try await prompted.summarize(
            transcript,
            moments: moments,
            template: template,
            language: language
        ) { request in
            try await parsedAnswer(
                instructions: request.instructions + "\n" + JSONSummary.format(for: template, language: language),
                prompt: request.prompt,
                maximumTokens: Self.maximumAnswerTokens,
                expecting: "a summary"
            ) { JSONSummary.summary(from: $0, template: template) }
        } title: { summary in
            try await self.title(for: summary)
        }
    }

    /// Splits transcripts in pieces of at most `pieceTokens`. Throws
    /// `SummarizationError.unavailable` if the model isn't downloaded.
    private func prompted() throws -> PromptedSummarizer {
        if case .unavailable(let reason) = availability { throw SummarizationError.unavailable(reason) }
        return PromptedSummarizer(maxTokens: Self.pieceTokens)
    }

    /// The model's answer, read with `parse`. Sampling varies the answer, so one that `parse`
    /// can't read, such as JSON cut short, is asked for once more before giving up.
    private func parsedAnswer<Value>(
        instructions: String,
        prompt: String,
        maximumTokens: Int,
        expecting what: String,
        parse: (String) -> Value?
    ) async throws -> Value {
        for attempt in 1...2 {
            let answer = try await runtime.respond(
                instructions: instructions,
                prompt: prompt,
                maximumTokens: maximumTokens
            )
            if let value = parse(answer) { return value }
            summaryLogger.error(
                "\(self.model.displayName, privacy: .public) answered without \(what, privacy: .public) (attempt \(attempt)): \(answer, privacy: .private)"
            )
        }
        throw SummarizationError.failed("\(model.displayName) didn't answer with \(what).")
    }

    /// A title for `summary`, for small models that stop before the last key.
    private func title(for summary: NoteSummary) async throws -> String {
        let answer = try await runtime.respond(
            instructions: SummaryPrompt.titleInstructions(language: summary.language),
            prompt: summary.plainText,
            maximumTokens: 40
        )
        return SummaryPrompt.title(from: answer)
    }

    public func nameSpeakers(_ speakers: [String], in transcript: Transcript) async throws -> [String: String] {
        try await prompted().nameSpeakers(speakers, in: transcript) { request in
            try await parsedAnswer(
                instructions: request.instructions + "\n" + SpeakerNaming.jsonFormat,
                prompt: request.prompt,
                maximumTokens: Self.maximumNamesTokens,
                expecting: "speaker names",
                parse: SpeakerNaming.guesses(fromJSON:)
            )
        }
    }

    public func catchUp(on transcript: Transcript, language: String?) async throws -> [String] {
        let prompted = try self.prompted()
        let language = language ?? TranscriptLanguage.code(of: transcript)
        return try await prompted.catchUp(on: transcript, language: language) { request in
            try await parsedAnswer(
                instructions: request.instructions + "\n" + JSONSummary.catchUpFormat(language: language),
                prompt: request.prompt,
                maximumTokens: Self.maximumAnswerTokens / 2,
                expecting: "a catch-up",
                parse: JSONSummary.catchUpPoints(from:)
            )
        }
    }
}
