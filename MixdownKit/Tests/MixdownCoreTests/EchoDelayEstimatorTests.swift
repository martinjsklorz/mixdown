import Foundation
import Testing

@testable import MixdownCore

enum EchoDelayFixtures {
    /// Noise that's the same every run, as uncorrelated with itself as speech is with its echo.
    static func noise(count: Int, seed: UInt64, level: Float) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * level
        }
    }

    /// System audio, and a microphone that hears it `delay` samples later (earlier if negative),
    /// quieter and over a voice of its own.
    static func recording(seconds: Int, delay: Int) -> (systemAudio: [Float], microphone: [Float]) {
        let count = seconds * Int(AudioChunk.sampleRate)
        let systemAudio = noise(count: count, seed: 1, level: 0.3)
        let voice = noise(count: count, seed: 2, level: 0.1)
        let microphone = (0..<count).map { index in
            let echoIndex = index - delay
            return voice[index] + (systemAudio.indices.contains(echoIndex) ? 0.5 * systemAudio[echoIndex] : 0)
        }
        return (systemAudio, microphone)
    }
}

struct EchoDelayEstimatorTests {
    private func estimate(delay: Int) -> EchoDelayEstimator.Estimate? {
        let (systemAudio, microphone) = EchoDelayFixtures.recording(seconds: 4, delay: delay)
        var estimator = EchoDelayEstimator()
        let window = EchoDelayEstimator.windowSize
        return estimator.add(
            microphone: Array(microphone[16_000..<(16_000 + window)]),
            reference: Array(systemAudio[16_000..<(16_000 + window)])
        )
    }

    @Test(arguments: [4_000, 800, -2_400, -12_000])
    func findsTheEchoLateOrEarly(delay: Int) throws {
        let found = try #require(estimate(delay: delay))
        #expect(abs(found.delay - delay) <= 4)
    }

    @Test func findsNothingWithoutSystemAudio() {
        var estimator = EchoDelayEstimator()
        let window = EchoDelayEstimator.windowSize
        let microphone = EchoDelayFixtures.noise(count: window, seed: 2, level: 0.1)
        #expect(estimator.add(microphone: microphone, reference: [Float](repeating: 0, count: window)) == nil)
    }

    @Test func findsNothingInUnrelatedAudio() {
        var estimator = EchoDelayEstimator()
        let window = EchoDelayEstimator.windowSize
        let microphone = EchoDelayFixtures.noise(count: window, seed: 2, level: 0.1)
        let systemAudio = EchoDelayFixtures.noise(count: window, seed: 3, level: 0.3)
        #expect(estimator.add(microphone: microphone, reference: systemAudio) == nil)
    }
}

struct EchoRemoverAlignmentTests {
    /// Runs a recording whose echo comes `delay` samples after the system audio's timestamps
    /// through a remover, writing the system audio as it would arrive.
    private func run(delay: Int) -> (EchoRemover, SubtractingEchoCanceller) {
        let (systemAudio, microphone) = EchoDelayFixtures.recording(seconds: 6, delay: delay)
        let reference = EchoReference()
        reference.beginWriting()
        let canceller = SubtractingEchoCanceller()
        let remover = EchoRemover(canceller: canceller, reference: reference, startHostTime: 100)
        let piece = 1_600
        for start in stride(from: 0, to: microphone.count, by: piece) {
            reference.write(
                AudioChunk(
                    samples: Array(systemAudio[start..<(start + piece)]),
                    hostTime: 100 + Double(start) / AudioChunk.sampleRate
                )
            )
            _ = remover.process(Array(microphone[start..<(start + piece)]))
        }
        _ = remover.finish()
        return (remover, canceller)
    }

    @Test func movesTheReferenceWhenTheEchoComesBeforeIt() {
        let (remover, canceller) = run(delay: -4_800)

        #expect(abs(remover.lead - (EchoRemover.targetEchoDelay + 4_800)) <= 4)
        #expect(canceller.resetCount == 1)
    }

    @Test func leavesAnEchoInReachAlone() {
        let (remover, canceller) = run(delay: 3_200)

        #expect(remover.lead == EchoRemover.referenceLead)
        #expect(canceller.resetCount == 0)
    }
}
