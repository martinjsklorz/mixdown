@testable import MixdownSpeechSwift
import Testing

struct RecognitionProgressTests {
    private let share = RecognitionProgress.detectionShare

    @Test func weighsPiecesByLength() {
        let plan = RecognitionProgress(pieceDurations: [30, 10])

        #expect(plan.completed(0) == share)
        #expect(abs(plan.completed(1) - (share + (1 - share) * 0.75)) < 1e-9)
        #expect(plan.completed(2) == 1)
    }

    @Test func aSinglePieceMovesWhileItRuns() {
        let plan = RecognitionProgress(pieceDurations: [600])

        let halfway = plan.running(0, elapsed: 30, expected: 60)
        let late = plan.running(0, elapsed: 600, expected: 60)

        #expect(abs(halfway - (share + (1 - share) * 0.45)) < 1e-9)
        #expect(late > plan.running(0, elapsed: 60, expected: 60))
        #expect(late < 1)
    }

    @Test func estimateIsContinuousAndBounded() {
        let atExpected = RecognitionProgress.estimate(elapsed: 10, expected: 10)
        let justAfter = RecognitionProgress.estimate(elapsed: 10.001, expected: 10)

        #expect(abs(atExpected - RecognitionProgress.estimatedShare) < 1e-9)
        #expect(justAfter > atExpected && justAfter - atExpected < 1e-3)
        #expect(RecognitionProgress.estimate(elapsed: 1_000, expected: 10) < 1)
        #expect(RecognitionProgress.estimate(elapsed: 0, expected: 10) == 0)
        #expect(RecognitionProgress.estimate(elapsed: 5, expected: 0) == 0)
    }

    @Test func runningStaysWithinThePiecesShare() {
        let plan = RecognitionProgress(pieceDurations: [10, 10, 10])
        let value = plan.running(1, elapsed: 1_000, expected: 1)
        #expect(value > plan.completed(1) && value < plan.completed(2))
    }

    @Test func zeroLengthPiecesShareEvenly() {
        let plan = RecognitionProgress(pieceDurations: [0, 0])
        #expect(abs(plan.completed(1) - (share + (1 - share) / 2)) < 1e-9)
        #expect(plan.completed(2) == 1)
    }

    @Test func detectionFillsItsShare() {
        #expect(RecognitionProgress.detection(0.5) == share / 2)
        #expect(RecognitionProgress.detection(2) == share)
    }
}
