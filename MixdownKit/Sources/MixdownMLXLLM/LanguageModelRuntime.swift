import Foundation
internal import MLX
internal import MLXLLM
internal import MLXLMCommon
import MixdownCore

/// Keeps one `MLXLanguageModel` in memory while it's used: loaded on the first answer asked for,
/// and unloaded again once none has been for `idleUnloadDelay`. Loading it again from disk takes
/// seconds; keeping it costs 1–5 GB.
actor LanguageModelRuntime {
    private let model: MLXLanguageModel
    private var container: ModelContainer?
    private var loading: Task<ModelContainer, any Error>?
    /// Answers being generated. The model stays loaded while there are any.
    private var activeAnswers = 0
    private var pendingUnload: Task<Void, Never>?

    /// Summaries come in a burst of answers, one per piece; catch-ups a few minutes apart.
    private static let idleUnloadDelay: Duration = .seconds(90)

    init(model: MLXLanguageModel) {
        self.model = model
    }

    /// The model's answer to `prompt`, in a fresh conversation so earlier pieces don't take up
    /// the context. Downloads the model if it isn't on disk. Honors task cancellation.
    func respond(instructions: String, prompt: String, maximumTokens: Int) async throws -> String {
        activeAnswers += 1
        pendingUnload?.cancel()
        defer {
            activeAnswers -= 1
            scheduleUnload()
        }
        let container = try await loadedContainer()
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

    func unload() {
        pendingUnload?.cancel()
        pendingUnload = nil
        loading?.cancel()
        loading = nil
        guard container != nil else { return }
        container = nil
        // Freed weights land in MLX's buffer cache, which would keep holding the memory.
        Memory.clearCache()
    }

    // MARK: - Loading

    /// Concurrent callers share one load; a failed load is retried by the next call.
    private func loadedContainer() async throws -> ModelContainer {
        if let container { return container }
        let task = loading ?? startLoading()
        do {
            let loaded = try await task.value
            if container == nil { container = loaded }
            if loading == task { loading = nil }
            return loaded
        } catch {
            if loading == task { loading = nil }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw SummarizationError.unavailable(error.localizedDescription)
        }
    }

    private func startLoading() -> Task<ModelContainer, any Error> {
        let model = self.model
        let task = Task {
            let started = ContinuousClock.now
            do {
                let directory = try await ModelFiles.download(model) { _ in }
                let container = try await LLMModelFactory.shared.loadContainer(
                    from: directory,
                    using: TransformersTokenizerLoader()
                )
                summaryLogger.info(
                    "Loaded \(model.displayName, privacy: .public) in \(String(describing: ContinuousClock.now - started), privacy: .public)"
                )
                return container
            } catch {
                summaryLogger.error(
                    "Loading \(model.displayName, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
                throw error
            }
        }
        loading = task
        return task
    }

    // MARK: - Unloading

    private func scheduleUnload() {
        pendingUnload?.cancel()
        guard activeAnswers == 0, container != nil else { return }
        let delay = Self.idleUnloadDelay
        pendingUnload = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard activeAnswers == 0, loading == nil, container != nil else { return }
        unload()
        summaryLogger.info("Unloaded \(self.model.displayName, privacy: .public) after being idle")
    }
}
