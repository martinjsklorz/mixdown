import Foundation
import Testing

@testable import MixdownCore

struct SerialTaskQueueTests {
    struct Failure: Error {}

    @Test func runsOperationsInOrderOneAtATime() async throws {
        let queue = SerialTaskQueue()
        let events = LockedValue<[String]>([])
        let gate = Gate()

        let first = Task {
            try await queue.run {
                events.update { $0.append("start 1") }
                await gate.wait()
                events.update { $0.append("end 1") }
            }
        }
        try await waitForEvents(events, count: 1)
        let second = Task {
            try await queue.run {
                events.update { $0.append("start 2") }
                events.update { $0.append("end 2") }
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.current == ["start 1"])

        await gate.open()
        try await first.value
        try await second.value
        #expect(events.current == ["start 1", "end 1", "start 2", "end 2"])
    }

    @Test func aFailingOperationDoesNotHoldUpTheNext() async throws {
        let queue = SerialTaskQueue()

        await #expect(throws: Failure.self) {
            try await queue.run { throw Failure() }
        }
        #expect(try await queue.run { 42 } == 42)
    }

    @Test func cancellingAWaitingCallerReturnsAtOnceAndCancelsOnlyItsOwnOperation() async throws {
        let queue = SerialTaskQueue()
        let events = LockedValue<[String]>([])
        let gate = Gate()

        let running = Task {
            try await queue.run {
                events.update { $0.append("start 1") }
                await gate.wait()
                events.update { $0.append("end 1") }
            }
        }
        try await waitForEvents(events, count: 1)
        let waiting = Task {
            try await queue.run { events.update { $0.append("cancelled one ran") } }
        }
        let later = Task {
            try await queue.run { events.update { $0.append("start 3") } }
        }
        try await Task.sleep(for: .milliseconds(20))

        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        // The running operation goes on, and the later one still waits for it.
        try await Task.sleep(for: .milliseconds(20))
        #expect(events.current == ["start 1"])

        await gate.open()
        try await running.value
        try await later.value
        #expect(events.current == ["start 1", "end 1", "start 3"])
    }

    /// Polls until `events` has `count` entries.
    private func waitForEvents(_ events: LockedValue<[String]>, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while events.current.count < count {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(count) event(s)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
