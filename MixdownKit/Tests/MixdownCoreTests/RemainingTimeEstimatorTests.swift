import Foundation
import MixdownCore
import Testing

struct RemainingTimeEstimatorTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func noEstimateUntilMinimumElapsed() {
        var estimator = RemainingTimeEstimator(minimumElapsed: 3)
        estimator.add(progress: 0, at: at(0))
        #expect(estimator.remaining == nil)
        estimator.add(progress: 0.1, at: at(2))
        #expect(estimator.remaining == nil)
    }

    @Test func extrapolatesFromSteadyProgress() {
        var estimator = RemainingTimeEstimator()
        estimator.add(progress: 0, at: at(0))
        estimator.add(progress: 0.25, at: at(10))
        // 25% per 10 s, 75% left.
        #expect(estimator.remaining == 30)
    }

    @Test func noEstimateWhileStalled() {
        var estimator = RemainingTimeEstimator()
        estimator.add(progress: 0.4, at: at(0))
        estimator.add(progress: 0.4, at: at(20))
        #expect(estimator.remaining == nil)
    }

    @Test func followsRecentSpeedWithinWindow() throws {
        var estimator = RemainingTimeEstimator(window: 30)
        // Fast at first: 50% in 10 s.
        estimator.add(progress: 0, at: at(0))
        estimator.add(progress: 0.5, at: at(10))
        // Then slow: 10% per 30 s.
        estimator.add(progress: 0.55, at: at(25))
        estimator.add(progress: 0.6, at: at(40))
        estimator.add(progress: 0.7, at: at(70))
        // Window now spans t=40...70: 10% per 30 s, 30% left → 90 s.
        let remaining = try #require(estimator.remaining)
        #expect(abs(remaining - 90) < 0.001)
    }

    @Test func restartsWhenProgressGoesBackwards() {
        var estimator = RemainingTimeEstimator()
        estimator.add(progress: 0, at: at(0))
        estimator.add(progress: 0.5, at: at(10))
        estimator.add(progress: 0.1, at: at(11))
        #expect(estimator.remaining == nil)
    }
}
