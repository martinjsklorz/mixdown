import Synchronization

/// Runs operations one at a time: each starts after every earlier one has finished, so even an
/// actor's reentrant `await`s can't interleave two of them. Cancelling a caller cancels its own
/// operation, running or still waiting, and no other.
public final class SerialTaskQueue: Sendable {
    /// Finishes when the last operation queued so far has.
    private let last = Mutex<Task<Void, Never>?>(nil)

    public init() {}

    public func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let job = last.withLock { last in
            let previous = last
            let job = Task {
                await previous?.value
                try Task.checkCancellation()
                return try await operation()
            }
            last = Task { _ = await job.result }
            return job
        }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }
}
