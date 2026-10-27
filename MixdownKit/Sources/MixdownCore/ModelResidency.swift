import Synchronization
import os

let modelLogger = Logger(subsystem: "app.mixdown", category: "models")

/// Keeps one loaded model in memory while it's needed: loaded on first use, shared by concurrent
/// callers, and unloaded again once nobody has needed it for `idleUnloadDelay`. Loading a model
/// again from disk takes seconds; keeping it costs gigabytes.
///
/// Every engine that loads its own weights (speech-swift's transcription models, the MLX language
/// models) keeps them here, so loading, idle unloading and freeing the memory work the same for all.
///
/// Callers hold the model with `retain()` while they use it (a transcription, a recording, an
/// answer) and `release()` it afterwards; it isn't unloaded for being idle in between.
///
/// Switching models replaces the engine rather than calling `unload()`, so releasing the last
/// reference unloads the model too.
public actor ModelResidency<Model: Sendable> {
    public typealias Progress = @Sendable (Double) -> Void

    private let name: String
    private let idleUnloadDelay: Duration
    private let loader: @Sendable (_ progress: @escaping Progress) async throws -> Model
    private let willUnload: @Sendable (Model) -> Void
    private let didUnload: @Sendable () -> Void

    /// A load under way and the callers waiting for it.
    private struct Loading {
        let id: Int
        let task: Task<Void, Never>
        let progress: ProgressRelay
        var waiters: [Int: CheckedContinuation<Model, any Error>] = [:]
    }

    private var model: Model?
    private var loading: Loading?
    /// Counts `unload()` calls, so a load that finishes after one is dropped.
    private var generation = 0
    /// For telling loads and their waiters apart.
    private var lastID = 0
    /// Callers between `retain()` and `release()`. Outside the actor, so retaining never waits on it.
    private nonisolated let users = Mutex(0)
    private var pendingUnload: Task<Void, Never>?

    /// - Parameters:
    ///   - name: The model's name, for the log.
    ///   - load: Loads the model, downloading it if needed, reporting 0...1.
    ///   - willUnload: Called with the model before it's dropped, to free what the model doesn't
    ///     free on its own.
    ///   - didUnload: Called once the model is dropped, e.g. to clear MLX's buffer cache, which
    ///     otherwise keeps holding the freed weights.
    public init(
        name: String,
        idleUnloadDelay: Duration,
        load: @escaping @Sendable (_ progress: @escaping Progress) async throws -> Model,
        willUnload: @escaping @Sendable (Model) -> Void = { _ in },
        didUnload: @escaping @Sendable () -> Void = {}
    ) {
        self.name = name
        self.idleUnloadDelay = idleUnloadDelay
        self.loader = load
        self.willUnload = willUnload
        self.didUnload = didUnload
    }

    deinit {
        pendingUnload?.cancel()
        loading?.task.cancel()
        // A finished load task keeps its result, i.e. the model.
        loading = nil
        guard model != nil else { return }
        if let model { willUnload(model) }
        // Dropped before `didUnload`, or weights freed only with the instance (MOSS's) would miss
        // a cache clear.
        model = nil
        didUnload()
    }

    /// Whether the model is in memory.
    public var isLoaded: Bool { model != nil }

    /// The model, loaded if it isn't. Concurrent calls share one load; a failed load is retried by
    /// the next call. Throws what the loader throws.
    ///
    /// Cancelling the calling task throws `CancellationError` right away. The load goes on for the
    /// other callers sharing it, and stops once none is left. `unload()` during the load throws
    /// `CancellationError` for every caller, and the model stays unloaded.
    ///
    /// Unless the model is retained, it's unloaded `idleUnloadDelay` after the last call.
    public func load(progress: Progress? = nil) async throws -> Model {
        defer { scheduleUnload() }
        if let model {
            progress?(1)
            return model
        }
        try Task.checkCancellation()

        let loading = self.loading ?? startLoading()
        if let progress { loading.progress.add(progress) }
        lastID += 1
        let waiter = lastID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.loading?.waiters[waiter] = continuation
            }
        } onCancel: {
            Task { await self.leave(waiter) }
        }
    }

    /// Keeps the model from being unloaded for being idle until `release()`. Doesn't load it.
    public nonisolated func retain() {
        users.withLock { $0 += 1 }
    }

    /// Ends a `retain()`; once nothing retains the model, it's unloaded after `idleUnloadDelay`.
    public nonisolated func release() {
        users.withLock { $0 = max($0 - 1, 0) }
        Task { [weak self] in await self?.scheduleUnload() }
    }

    /// Unloads the model now, retained or not, and cancels a load under way: its callers get
    /// `CancellationError`, and what it loads anyway is dropped.
    public func unload() {
        pendingUnload?.cancel()
        pendingUnload = nil
        generation += 1
        if let loading {
            self.loading = nil
            loading.task.cancel()
            for waiter in loading.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
        guard model != nil else { return }
        if let model { willUnload(model) }
        // See `deinit`.
        model = nil
        didUnload()
    }

    // MARK: - Loading

    private func startLoading() -> Loading {
        let relay = ProgressRelay()
        let (name, loader, didUnload, generation) = (self.name, self.loader, self.didUnload, self.generation)
        lastID += 1
        let id = lastID
        // Holds the actor only weakly, like the unload timer, so releasing it still frees the model.
        let task = Task { [weak self] in
            let started = ContinuousClock.now
            let result: Result<Model, any Error>
            do {
                result = .success(try await loader { relay.report($0) })
                relay.report(1)
                modelLogger.info(
                    "Loaded \(name, privacy: .public) in \(String(describing: ContinuousClock.now - started), privacy: .public)"
                )
            } catch {
                if error is CancellationError || Task.isCancelled {
                    modelLogger.info("Loading \(name, privacy: .public) cancelled")
                } else {
                    modelLogger.error(
                        "Loading \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                    )
                }
                result = .failure(error)
            }
            let dropped = await self?.finishLoading(id, generation: generation, with: consume result) ?? false
            // Only now that nothing holds the dropped model; see `deinit`.
            if dropped { didUnload() }
        }
        let loading = Loading(id: id, task: task, progress: relay)
        self.loading = loading
        return loading
    }

    /// Hands the result of load `id`, started in `generation`, to its waiters. A model it loaded
    /// is kept unless `unload()` was called since, or another load got there first; otherwise it's
    /// dropped, and `true` returned for the caller to call `didUnload` once it's gone. A load that
    /// finished despite being cancelled is still good.
    private func finishLoading(_ id: Int, generation: Int, with result: Result<Model, any Error>) -> Bool {
        var waiters: [CheckedContinuation<Model, any Error>] = []
        if let loading, loading.id == id {
            waiters = Array(loading.waiters.values)
            // Cleared so the next call retries a failed load.
            self.loading = nil
        }
        switch result {
        case .success(let loaded):
            let isKept = model == nil && generation == self.generation
            if isKept { model = loaded } else { willUnload(loaded) }
            if let model {
                for waiter in waiters { waiter.resume(returning: model) }
            } else {
                for waiter in waiters { waiter.resume(throwing: CancellationError()) }
            }
            scheduleUnload()
            return !isKept
        case .failure(let error):
            for waiter in waiters { waiter.resume(throwing: error) }
            return false
        }
    }

    /// Stops `waiter`'s wait with `CancellationError`, and the load once nobody waits for it.
    private func leave(_ waiter: Int) {
        guard let continuation = loading?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if let loading, loading.waiters.isEmpty {
            self.loading = nil
            loading.task.cancel()
        }
    }

    // MARK: - Unloading

    private var isInUse: Bool { users.withLock { $0 } > 0 }

    /// Unloads the model after `idleUnloadDelay`, unless it's retained or loaded again first.
    private func scheduleUnload() {
        pendingUnload?.cancel()
        pendingUnload = nil
        guard !isInUse, model != nil else { return }
        let delay = idleUnloadDelay
        pendingUnload = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard !isInUse, loading == nil, model != nil else { return }
        unload()
        modelLogger.info("Unloaded \(self.name, privacy: .public) after being idle")
    }
}

/// Fans load progress out to every caller sharing a load, never moving backwards.
private final class ProgressRelay: Sendable {
    private struct State {
        var observers: [@Sendable (Double) -> Void] = []
        var value: Double = 0
    }

    private let state = Mutex(State())

    func add(_ observer: @escaping @Sendable (Double) -> Void) {
        let value = state.withLock {
            $0.observers.append(observer)
            return $0.value
        }
        observer(value)
    }

    func report(_ fraction: Double) {
        let (observers, value) = state.withLock { current -> ([@Sendable (Double) -> Void], Double) in
            current.value = max(current.value, min(max(fraction, 0), 1))
            return (current.observers, current.value)
        }
        observers.forEach { $0(value) }
    }
}
