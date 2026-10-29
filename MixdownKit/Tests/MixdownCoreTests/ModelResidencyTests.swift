import Foundation
import MixdownCore
import Synchronization
import Testing

struct ModelResidencyTests {
    private final class Weights: Sendable {
        let id: Int
        init(id: Int) { self.id = id }
    }

    /// Counts what a `ModelResidency` does with its model, and can make loads fail or wait.
    private final class Probe: Sendable {
        private struct State {
            var loads = 0
            var willUnloads = 0
            var didUnloads = 0
            var failuresLeft = 0
            /// Whether the weights were still alive when `didUnload` ran.
            var weightsAliveAtDidUnload: [Bool] = []
            weak var lastWeights: Weights?
        }

        private let state = Mutex(State())
        let loadDelay: Duration
        /// Whether loads take `loadDelay` even when cancelled, as a loader that doesn't check.
        let ignoresCancellation: Bool

        init(loadDelay: Duration = .zero, failures: Int = 0, ignoresCancellation: Bool = false) {
            self.loadDelay = loadDelay
            self.ignoresCancellation = ignoresCancellation
            state.withLock { $0.failuresLeft = failures }
        }

        var loads: Int { state.withLock { $0.loads } }
        var willUnloads: Int { state.withLock { $0.willUnloads } }
        var didUnloads: Int { state.withLock { $0.didUnloads } }
        var weightsAliveAtDidUnload: [Bool] { state.withLock { $0.weightsAliveAtDidUnload } }

        func residency(idleUnloadDelay: Duration = .seconds(60)) -> ModelResidency<Weights> {
            ModelResidency(
                name: "Test",
                idleUnloadDelay: idleUnloadDelay,
                load: { progress in
                    let (id, fails) = self.state.withLock {
                        $0.loads += 1
                        let fails = $0.failuresLeft > 0
                        if fails { $0.failuresLeft -= 1 }
                        return ($0.loads, fails)
                    }
                    progress(0.5)
                    if self.ignoresCancellation {
                        let delay = self.loadDelay
                        await Task.detached { try? await Task.sleep(for: delay) }.value
                    } else if self.loadDelay > .zero {
                        try await Task.sleep(for: self.loadDelay)
                    }
                    if fails { throw TestError() }
                    let weights = Weights(id: id)
                    self.state.withLock { $0.lastWeights = weights }
                    return weights
                },
                willUnload: { _ in self.state.withLock { $0.willUnloads += 1 } },
                didUnload: {
                    self.state.withLock {
                        $0.didUnloads += 1
                        $0.weightsAliveAtDidUnload.append($0.lastWeights != nil)
                    }
                }
            )
        }
    }

    private struct TestError: Error {}

    @Test func concurrentCallersShareOneLoad() async throws {
        let probe = Probe(loadDelay: .milliseconds(100))
        let residency = probe.residency()
        async let first = residency.load()
        async let second = residency.load()
        let (a, b) = try await (first, second)
        #expect(a === b)
        #expect(probe.loads == 1)
        // Loaded already: no second load.
        _ = try await residency.load()
        #expect(probe.loads == 1)
    }

    @Test func progressReachesEveryCallerAndEnds() async throws {
        let probe = Probe(loadDelay: .milliseconds(50))
        let residency = probe.residency()
        let first = Mutex<[Double]>([])
        let second = Mutex<[Double]>([])
        async let a = residency.load { value in first.withLock { $0.append(value) } }
        async let b = residency.load { value in second.withLock { $0.append(value) } }
        _ = try await (a, b)
        for values in [first.withLock { $0 }, second.withLock { $0 }] {
            #expect(values.last == 1)
            #expect(values == values.sorted())
        }
    }

    @Test func failedLoadIsRetriedByNextCall() async throws {
        let probe = Probe(failures: 1)
        let residency = probe.residency()
        await #expect(throws: TestError.self) { try await residency.load() }
        let weights = try await residency.load()
        #expect(weights.id == 2)
        #expect(await residency.isLoaded)
    }

    @Test func unloadsOnceIdle() async throws {
        let probe = Probe()
        let residency = probe.residency(idleUnloadDelay: .milliseconds(50))
        _ = try await residency.load()
        #expect(await residency.isLoaded)
        try await waitUntil { await !residency.isLoaded }
        #expect(probe.willUnloads == 1)
        #expect(probe.didUnloads == 1)
    }

    @Test func staysLoadedWhileRetained() async throws {
        let probe = Probe()
        let residency = probe.residency(idleUnloadDelay: .milliseconds(30))
        residency.retain()
        _ = try await residency.load()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await residency.isLoaded)

        residency.release()
        try await waitUntil { await !residency.isLoaded }
        #expect(probe.didUnloads == 1)
    }

    @Test func unloadDropsWeightsBeforeDidUnload() async throws {
        let probe = Probe()
        let residency = probe.residency()
        residency.retain()
        _ = try await residency.load()
        await residency.unload()
        #expect(await !residency.isLoaded)
        #expect(probe.willUnloads == 1)
        #expect(probe.weightsAliveAtDidUnload == [false])
        // Unloading again does nothing.
        await residency.unload()
        #expect(probe.didUnloads == 1)
    }

    /// Switching models replaces the engine without unloading; the old model must still be freed.
    @Test func releasingTheResidencyUnloads() async throws {
        let probe = Probe()
        var residency: ModelResidency<Weights>? = probe.residency()
        _ = try await residency?.load()
        residency = nil
        try await waitUntil { probe.didUnloads == 1 }
        #expect(probe.willUnloads == 1)
        #expect(probe.weightsAliveAtDidUnload == [false])
    }

    @Test func releasingAnUnloadedResidencyDoesNothing() async throws {
        let probe = Probe()
        var residency: ModelResidency<Weights>? = probe.residency()
        _ = residency
        residency = nil
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.didUnloads == 0)
    }

    @Test func cancellingTheOnlyCallerStopsTheLoad() async throws {
        let probe = Probe(loadDelay: .seconds(10))
        let residency = probe.residency()
        let caller = Task { try await residency.load() }
        try await Task.sleep(for: .milliseconds(50))
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(await !residency.isLoaded)
    }

    @Test func cancellingOneOfTwoCallersKeepsTheSharedLoad() async throws {
        // Scaled, so a slow machine doesn't finish the load before the first caller is cancelled.
        let probe = Probe(loadDelay: .milliseconds(200) * testTimeoutScale)
        let residency = probe.residency()
        let first = Task { try await residency.load() }
        try await Task.sleep(for: .milliseconds(30) * testTimeoutScale)
        let second = Task { try await residency.load() }
        try await Task.sleep(for: .milliseconds(30) * testTimeoutScale)
        first.cancel()
        // The cancelled caller doesn't wait for the load.
        let cancelled = ContinuousClock.now
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(ContinuousClock.now - cancelled < .milliseconds(100) * testTimeoutScale)
        let weights = try await second.value
        #expect(weights.id == 1)
        #expect(probe.loads == 1)
    }

    @Test func unloadDuringLoadFailsWaitersAndStaysUnloaded() async throws {
        let probe = Probe(loadDelay: .milliseconds(150) * testTimeoutScale, ignoresCancellation: true)
        let residency = probe.residency()
        let first = Task { try await residency.load() }
        let second = Task { try await residency.load() }
        try await Task.sleep(for: .milliseconds(30) * testTimeoutScale)
        await residency.unload()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        // The load finishes anyway; what it loaded is dropped, and nothing loads it again.
        try await waitUntil { probe.didUnloads == 1 }
        #expect(probe.willUnloads == 1)
        #expect(probe.loads == 1)
        #expect(probe.weightsAliveAtDidUnload == [false])
        #expect(await !residency.isLoaded)
    }
}
