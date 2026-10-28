import Foundation
import Testing

@testable import MixdownCore

/// The gate that skips windows whose system audio is much quieter than it has been.
struct EchoDelayGateTests {
    private static let delay = 4_000
    /// 30 dB down.
    private static let quiet: Float = 0.0316
    private static let recording = EchoDelayFixtures.recording(seconds: 14, delay: delay)

    /// Adds window `index` of the recording, every sample scaled by `gain`.
    private static func add(
        window index: Int,
        gain: Float,
        to estimator: inout EchoDelayEstimator
    ) -> EchoDelayEstimator.Estimate? {
        let start = 16_000 + index * EchoDelayEstimator.hop
        let range = start..<(start + EchoDelayEstimator.windowSize)
        return estimator.add(
            microphone: recording.microphone[range].map { $0 * gain },
            reference: recording.systemAudio[range].map { $0 * gain }
        )
    }

    @Test func followsSystemAudioThatStaysQuieter() throws {
        var estimator = EchoDelayEstimator()
        _ = Self.add(window: 0, gain: 1, to: &estimator)
        var found: EchoDelayEstimator.Estimate?
        for index in 1...20 {
            found = Self.add(window: index, gain: Self.quiet, to: &estimator)
        }
        let estimate = try #require(found)
        #expect(abs(estimate.delay - Self.delay) <= 4)
    }

    @Test func skipsAQuietWindowRightAfterALoudOne() {
        var estimator = EchoDelayEstimator()
        _ = Self.add(window: 0, gain: 1, to: &estimator)
        #expect(Self.add(window: 1, gain: Self.quiet, to: &estimator) == nil)

        // Not for lack of an echo: on its own, the same window finds it.
        var fresh = EchoDelayEstimator()
        #expect(Self.add(window: 1, gain: Self.quiet, to: &fresh) != nil)
    }
}
