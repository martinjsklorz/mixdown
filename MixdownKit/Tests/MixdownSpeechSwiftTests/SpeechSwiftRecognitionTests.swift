import Foundation
import MixdownCore
import Testing

@testable import MixdownSpeechSwift

struct SpeechSwiftRecognitionTests {
    private struct ModelError: LocalizedError {
        var errorDescription: String? { "out of memory" }
    }

    private func piece(speech: (Double, Double), window: (Double, Double)) -> SpeechPiece {
        SpeechPiece(
            speech: TimeSpan(start: speech.0, end: speech.1),
            window: TimeSpan(start: window.0, end: window.1)
        )
    }

    private func recognize(
        _ pieces: [SpeechPiece],
        with recognizer: FakeRecognizer,
        seconds: Double = 40,
        progress: MonotonicProgress? = nil
    ) async throws -> (segments: [TranscriptSegment], speed: Double?) {
        try await SpeechSwiftEngine.recognize(
            [Float](repeating: 0, count: Int(seconds * AudioChunk.sampleRate)),
            pieces: pieces,
            recognizer: recognizer,
            hint: nil,
            vocabulary: [],
            initialSpeed: 1_000,
            progress: progress
        )
    }

    @Test func placesTimedOutputWithinTheWindow() async throws {
        let recognizer = FakeRecognizer([
            .success([
                RecognizedSegment(text: "Hello", timing: TimeSpan(start: 2, end: 3), speaker: "Speaker 1"),
                RecognizedSegment(text: "there", timing: TimeSpan(start: -1, end: 30)),
            ])
        ])

        let result = try await recognize([piece(speech: (11, 19), window: (10, 20))], with: recognizer)

        #expect(
            result.segments == [
                TranscriptSegment(start: 12, end: 13, text: "Hello", speaker: "Speaker 1"),
                TranscriptSegment(start: 10, end: 20, text: "there"),
            ]
        )
    }

    @Test func untimedOutputGetsTheSpeechBoundsAndEmptyTextIsDropped() async throws {
        let recognizer = FakeRecognizer([
            .success([RecognizedSegment(text: "  Hi.\n"), RecognizedSegment(text: " \n")]),
            .success([RecognizedSegment(text: "")]),
        ])

        let result = try await recognize(
            [piece(speech: (1, 2), window: (0.5, 2.5)), piece(speech: (5, 6), window: (4.5, 6.5))],
            with: recognizer
        )

        #expect(result.segments == [TranscriptSegment(start: 1, end: 2, text: "Hi.")])
        #expect(recognizer.inputs.map(\.count) == [32_000, 32_000])
    }

    @Test func cancellingStopsBeforeTheNextPiece() async {
        let recognizer = FakeRecognizer([.success([RecognizedSegment(text: "One")])])
        recognizer.onRecognize = { withUnsafeCurrentTask { $0?.cancel() } }

        await #expect(throws: CancellationError.self) {
            try await recognize(
                [piece(speech: (0, 1), window: (0, 1)), piece(speech: (2, 3), window: (2, 3))],
                with: recognizer
            )
        }
        #expect(recognizer.inputs.count == 1)
    }

    @Test func recognizerErrorsBecomeTranscriptionFailures() async {
        let recognizer = FakeRecognizer([.failure(ModelError())])

        do {
            _ = try await recognize([piece(speech: (0, 1), window: (0, 1))], with: recognizer)
            Issue.record("Expected an error")
        } catch let TranscriptionError.failed(reason) {
            #expect(reason == "out of memory")
        } catch {
            Issue.record("Unexpected \(error)")
        }
    }

    @Test func progressNeverMovesBackAndEndsWithTheLastPiece() async throws {
        let log = ProgressLog()
        let pieces = [piece(speech: (0, 10), window: (0, 10)), piece(speech: (20, 40), window: (20, 40))]
        let recognizer = FakeRecognizer([.success([]), .success([])])

        let result = try await recognize(pieces, with: recognizer, progress: MonotonicProgress(log.record))

        let reported = log.reported
        #expect(reported == reported.sorted())
        #expect(reported.last == RecognitionProgress(pieceDurations: [10, 20]).completed(2))
        // 30 s of audio is enough to time the model by.
        #expect(result.speed != nil)
    }

    @Test func tooLittleAudioMeasuresNoSpeed() async throws {
        let recognizer = FakeRecognizer([.success([])])

        let result = try await recognize([piece(speech: (0, 10), window: (0, 10))], with: recognizer)

        #expect(result.speed == nil)
    }

    @Test func monotonicProgressDropsStepsBackAndClamps() {
        let log = ProgressLog()
        let progress = MonotonicProgress(log.record)

        for value in [0.2, 0.1, 0.2, .nan, 0.5, 2, 0.9] { progress.report(value) }

        #expect(log.reported == [0.2, 0.5, 1])
    }

    @Test func sliceRoundsOutwardToWholeSamples() {
        let samples = (0..<32_000).map(Float.init)

        let slice = SpeechSwiftEngine.slice(samples, to: TimeSpan(start: 0.50003, end: 1.00001))

        #expect(slice.first == 8_000)
        #expect(slice.last == 16_000)
        #expect(SpeechSwiftEngine.slice(samples, to: TimeSpan(start: 1.5, end: 3)).count == 8_000)
        #expect(SpeechSwiftEngine.slice(samples, to: TimeSpan(start: 3, end: 4)).isEmpty)
    }

    @Test func languageCodeKeepsThePrimaryLanguage() {
        #expect(SpeechSwiftEngine.languageCode("de-DE") == "de")
        #expect(SpeechSwiftEngine.languageCode("pt_BR") == "pt")
        #expect(SpeechSwiftEngine.languageCode("EN") == "en")
        #expect(SpeechSwiftEngine.languageCode("") == nil)
        #expect(SpeechSwiftEngine.languageCode(nil) == nil)
    }

    @Test func liveModelRefusesWholeRecordingsWithoutLoading() async {
        let engine = SpeechSwiftEngine(model: .nemotronStreaming)

        await #expect(throws: TranscriptionError.self) {
            try await engine.transcribe([0, 0, 0], options: TranscriptionOptions(), progress: nil)
        }
    }

    @Test func offlineModelRefusesLiveSessionsWithoutLoading() async {
        let engine = SpeechSwiftEngine(model: .qwen3ASRSmall)

        await #expect(throws: TranscriptionError.self) {
            try await engine.makeLiveSession(options: TranscriptionOptions())
        }
    }
}
