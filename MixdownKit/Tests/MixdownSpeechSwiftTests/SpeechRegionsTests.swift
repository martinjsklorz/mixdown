import Testing

@testable import MixdownSpeechSwift

struct SpeechRegionsTests {
    private let frame = 0.032

    private func frames(_ runs: [(Float, Int)]) -> [Float] {
        runs.flatMap { [Float](repeating: $0.0, count: $0.1) }
    }

    @Test func keepsAShortReplyThatDipsInTheMiddle() {
        // "Ye-s": two 0.096 s bursts around one quiet frame. Each alone is too short.
        let probabilities = frames([(0.1, 20), (0.8, 3), (0.2, 1), (0.8, 3), (0.1, 20)])

        let regions = SpeechRegions.detect(in: probabilities, frameDuration: frame)

        #expect(regions.count == 1)
        #expect(abs(regions[0].start - 20 * frame) < 1e-9)
        #expect(abs(regions[0].end - 27 * frame) < 1e-9)
    }

    @Test func keepsAReplyShorterThanSilerosMinimum() {
        let probabilities = frames([(0.1, 20), (0.9, 6), (0.1, 20)])  // 0.19 s
        #expect(SpeechRegions.detect(in: probabilities, frameDuration: frame).count == 1)
    }

    @Test func dropsBlips() {
        let probabilities = frames([(0.1, 20), (0.9, 2), (0.1, 20)])  // 0.064 s
        #expect(SpeechRegions.detect(in: probabilities, frameDuration: frame).isEmpty)
    }

    @Test func appliesHysteresisAndSplitsAtRealPauses() {
        // Dips to 0.4 stay speech (above offset); a 0.32 s pause ends the region.
        let probabilities = frames([(0.9, 10), (0.4, 5), (0.9, 10), (0.1, 10), (0.6, 10)])

        let regions = SpeechRegions.detect(in: probabilities, frameDuration: frame)

        #expect(regions.count == 2)
        #expect(abs(regions[0].end - 25 * frame) < 1e-9)
        #expect(abs(regions[1].start - 35 * frame) < 1e-9)
        #expect(abs(regions[1].end - 45 * frame) < 1e-9)  // closed at the end of the audio
    }

    @Test func needsTheOnsetToStart() {
        let probabilities = frames([(0.45, 50)])
        #expect(SpeechRegions.detect(in: probabilities, frameDuration: frame).isEmpty)
    }
}
