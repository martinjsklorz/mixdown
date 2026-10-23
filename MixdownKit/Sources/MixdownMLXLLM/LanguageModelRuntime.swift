import Foundation
internal import MLX
internal import MLXLLM
internal import MLXLMCommon
import MixdownCore

/// Keeps one `MLXLanguageModel` in memory while it's used: loaded on the first answer asked for,
/// and unloaded again once none has been for `idleUnloadDelay`. Loading it again from disk takes
/// seconds; keeping it costs 1–5 GB.
final class LanguageModelRuntime: Sendable {
    private let model: MLXLanguageModel
    /// Retained by every answer being generated.
    private let residency: ModelResidency<ModelContainer>

    /// Summaries come in a burst of answers, one per piece; catch-ups a few minutes apart.
    private static let idleUnloadDelay: Duration = .seconds(90)

    init(model: MLXLanguageModel) {
        self.model = model
        // Switching models replaces the summarizer, so the residency's deinit frees the old model.
        self.residency = ModelResidency(
            name: model.displayName,
            idleUnloadDelay: Self.idleUnloadDelay,
            load: { _ in try await Self.load(model) },
            // Freed weights land in MLX's buffer cache, which would keep holding the memory.
            didUnload: { Memory.clearCache() }
        )
    }

    /// The model's answer to `prompt`, in a fresh conversation so earlier pieces don't take up
    /// the context. Downloads the model if it isn't on disk. Honors task cancellation.
    func respond(instructions: String, prompt: String, maximumTokens: Int) async throws -> String {
        residency.retain()
        defer { residency.release() }
        let container: ModelContainer
        do {
            container = try await residency.load()
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw SummarizationError.unavailable(error.localizedDescription)
        }
        try Task.checkCancellation()
        let session = ChatSession(
            container,
            instructions: instructions,
            // Low temperature: a summary should stick to the transcript, not be creative.
            generateParameters: GenerateParameters(maxTokens: maximumTokens, temperature: 0.3, topP: 0.9),
            // Qwen3 and Qwen3.5 think before answering unless told not to, which is slow and can
            // use up the answer's tokens. Templates that don't know the flag ignore it.
            additionalContext: ["enable_thinking": false]
        )
        let started = ContinuousClock.now
        let answer = try await session.respond(to: prompt)
        // A cancelled stream ends early rather than throwing.
        try Task.checkCancellation()
        summaryLogger.info(
            "\(self.model.displayName, privacy: .public) answered \(answer.count) characters for \(prompt.count) in \(String(describing: ContinuousClock.now - started), privacy: .public)"
        )
        return answer
    }

    func unload() async {
        await residency.unload()
    }

    /// Loads the model from disk, downloading what's missing or damaged first (see
    /// `ModelDirectory.loadPreferringCache`).
    private static func load(_ model: MLXLanguageModel) async throws -> ModelContainer {
        let directory = try ModelFiles.directory(for: model)
        return try await ModelDirectory.loadPreferringCache(
            model.repositoryID,
            cacheLooksComplete: ModelFiles.isComplete(directory),
            progress: { _ in }
        ) { offline, progress in
            if !offline { try await ModelFiles.fetch(model, into: directory, progress: progress) }
            return try await LLMModelFactory.shared.loadContainer(
                from: directory,
                using: TransformersTokenizerLoader()
            )
        }
    }
}
