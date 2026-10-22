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

    public func summarize(_ transcript: Transcript, template: SummaryTemplate) async throws -> NoteSummary {
        if case .unavailable(let reason) = availability { throw SummarizationError.unavailable(reason) }
        let language = TranscriptLanguage.code(of: transcript)
        let chunked = ChunkedSummarizer(maxTokens: Self.pieceTokens)
        var summary = try await chunked.summarize(transcript) { text, kind in
            let instructions = SummaryPrompt.instructions(for: kind, template: template, language: language)
            return try await parsedAnswer(
                instructions: instructions + "\n" + JSONSummary.format(for: template, language: language),
                prompt: SummaryPrompt.prompt(for: text, kind: kind),
                maximumTokens: Self.maximumAnswerTokens,
                expecting: "a summary"
            ) { JSONSummary.summary(from: $0, template: template) }
        }
        if summary.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !summary.isEmpty {
            summary.title = try await title(for: summary, language: language)
        }
        summary.language = language
        return summary
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

    /// A title for `summary`, for small models that stop before the last key. Empty if the
    /// model doesn't give one; the note is then titled with its date.
    private func title(for summary: NoteSummary, language: String?) async throws -> String {
        do {
            let answer = try await runtime.respond(
                instructions: SummaryPrompt.titleInstructions(language: language),
                prompt: summary.plainText,
                maximumTokens: 40
            )
            return SummaryPrompt.title(from: answer)
        } catch let error as CancellationError {
            throw error
        } catch {
            summaryLogger.error("\(self.model.displayName, privacy: .public) gave no title: \(error, privacy: .public)")
            return ""
        }
    }

    public func nameSpeakers(_ speakers: [String], in transcript: Transcript) async throws -> [String: String] {
        if case .unavailable(let reason) = availability { throw SummarizationError.unavailable(reason) }
        return try await SpeakerNaming.names(
            for: speakers,
            in: transcript,
            maxTokens: Self.pieceTokens
        ) { text, speakers in
            try await parsedAnswer(
                instructions: SpeakerNaming.instructions + "\n" + SpeakerNaming.jsonFormat,
                prompt: SpeakerNaming.prompt(for: text, speakers: speakers),
                maximumTokens: Self.maximumNamesTokens,
                expecting: "speaker names",
                parse: SpeakerNaming.guesses(fromJSON:)
            )
        }
    }

    public func catchUp(on transcript: Transcript, language: String?) async throws -> [String] {
        if case .unavailable(let reason) = availability { throw SummarizationError.unavailable(reason) }
        let language = language ?? TranscriptLanguage.code(of: transcript)
        let chunked = ChunkedSummarizer(maxTokens: Self.pieceTokens)
        let summary = try await chunked.summarize(transcript) { text, kind in
            let instructions = SummaryPrompt.catchUpInstructions(for: kind, language: language)
            let points = try await parsedAnswer(
                instructions: instructions + "\n" + JSONSummary.catchUpFormat(language: language),
                prompt: SummaryPrompt.prompt(for: text, kind: kind),
                maximumTokens: Self.maximumAnswerTokens / 2,
                expecting: "a catch-up",
                parse: JSONSummary.catchUpPoints(from:)
            )
            return NoteSummary(keyPoints: points)
        }
        return summary.keyPoints
    }
}
