import Synchronization

/// Runs operations one at a time: each starts after every earlier one has finished, so even an
/// actor's reentrant `await`s can't interleave two of them. Cancelling a caller cancels its own
/// operation, running or still waiting, and no other. One cancelled while waiting returns at once.
public final class SerialTaskQueue: Sendable {
    /// Finishes when the last operation queued so far has.
    private let last = Mutex<Task<Void, Never>?>(nil)

    public init() {}

    public func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let job = last.withLock { last in
            let previous = last
            let job = Task {
                if let previous { await Self.wait(for: previous) }
                try Task.checkCancellation()
                return try await operation()
            }
            // Waits for the earlier operations too, as a job cancelled while waiting ends early.
            last = Task {
                await previous?.value
                _ = await job.result
            }
            return job
        }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    /// Waits until `task` has finished or the current task is cancelled, whichever comes first.
    private static func wait(for task: Task<Void, Never>) async {
        let waiter = Waiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.wait(with: continuation)
                Task {
                    await task.value
                    waiter.resume()
                }
            }
        } onCancel: {
            waiter.resume()
        }
    }
}

/// A continuation resumed once, by whichever of the task finishing or the cancellation is first.
private final class Waiter: Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<Void, Never>)
        case resumed
    }

    private let state = Mutex(State.pending)

    func wait(with continuation: CheckedContinuation<Void, Never>) {
        let isResumed = state.withLock { state in
            guard case .pending = state else { return true }
            state = .waiting(continuation)
            return false
        }
        // Cancelled before it started waiting.
        if isResumed { continuation.resume() }
    }

    func resume() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state = .resumed }
            if case .waiting(let continuation) = state { return continuation }
            return nil
        }
        continuation?.resume()
    }
}
