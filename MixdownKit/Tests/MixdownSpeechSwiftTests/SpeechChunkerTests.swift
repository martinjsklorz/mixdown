@testable import MixdownSpeechSwift
import Testing

struct SpeechChunkerTests {
    private func pieces(
        _ regions: [(Double, Double)],
        probabilities: [Float] = [],
        frameDuration: Double = 1,
        audioDuration: Double,
        maxWindow: Double = 14,
        maxMergeGap: Double = 0.8,
        padding: Double = 0
    ) -> [SpeechPiece] {
        SpeechChunker.pieces(
            regions: regions.map { TimeSpan(start: $0.0, end: $0.1) },
            probabilities: probabilities,
            frameDuration: frameDuration,
            audioDuration: audioDuration,
            configuration: .init(maxWindowDuration: maxWindow, maxMergeGap: maxMergeGap, padding: padding)
        )
    }

    @Test func mergesCloseRegionsAndPadsIntoSilence() {
        let result = pieces([(0.5, 2), (2.5, 4), (10, 11)], audioDuration: 12, padding: 0.25)

        #expect(result == [
            SpeechPiece(speech: TimeSpan(start: 0.5, end: 4), window: TimeSpan(start: 0.25, end: 4.25)),
            SpeechPiece(speech: TimeSpan(start: 10, end: 11), window: TimeSpan(start: 9.75, end: 11.25)),
        ])
    }

    @Test func paddingStopsHalfwayToTheNeighbour() {
        let result = pieces([(1, 2), (2.9, 3.5)], audioDuration: 5, padding: 1)

        #expect(result.count == 2)
        #expect(result[0].window.end == result[1].window.start)
        #expect(result[0].window.end > 2 && result[0].window.end < 2.9)
    }

    @Test func splitsLongRegionsAtTheQuietestFrame() {
        var probabilities = [Float](repeating: 0.9, count: 30)
        probabilities[9] = 0.1   // frame centre 9.5 s
        probabilities[20] = 0.2  // frame centre 20.5 s

        let result = pieces([(0, 30)], probabilities: probabilities, audioDuration: 30)

        #expect(result.map(\.speech) == [
            TimeSpan(start: 0, end: 9.5),
            TimeSpan(start: 9.5, end: 20.5),
            TimeSpan(start: 20.5, end: 30),
        ])
        #expect(result.allSatisfy { $0.window.duration <= 14 })
    }

    @Test func splitsAtTheBudgetWithoutProbabilities() {
        let result = pieces([(0, 20)], audioDuration: 20)
        #expect(result.map(\.speech) == [TimeSpan(start: 0, end: 14), TimeSpan(start: 14, end: 20)])
    }

    @Test func clampsToTheRecordingAndDropsEmptyRegions() {
        let result = pieces([(8, 12), (-1, 2), (5, 5)], audioDuration: 10)
        #expect(result.map(\.speech) == [TimeSpan(start: 0, end: 2), TimeSpan(start: 8, end: 10)])
    }

    @Test func noRegionsProducesNoPieces() {
        #expect(pieces([], audioDuration: 10).isEmpty)
    }
}
