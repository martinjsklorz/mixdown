import Foundation
import Testing

@testable import MixdownCore

enum TalkFixtures {
    /// Speech-loud (-20 dBFS) for each `true`, quiet room noise (-60 dBFS) for each `false`, a
    /// second each.
    static func audio(_ seconds: [Bool]) -> [Float] {
        seconds.flatMap { isSpeech in
            Array(repeating: isSpeech ? Float(0.1) : 0.001, count: Int(AudioChunk.sampleRate))
        }
    }
}

struct SpeechActivityDetectorTests {
    @Test func findsSpeechBetweenQuietStretches() {
        var detector = SpeechActivityDetector()
        let speech = detector.add(TalkFixtures.audio([false, true, true, false, false, true, false]))

        #expect(abs(speech - 3) < 0.001)
        #expect(detector.spans.count == 2)
        #expect(abs(detector.spans[0].lowerBound - 1) < 0.001)
        #expect(abs(detector.spans[0].upperBound - 3) < 0.001)
        #expect(abs(detector.spans[1].lowerBound - 5) < 0.001)
        #expect(abs(detector.spans[1].upperBound - 6) < 0.001)
    }

    @Test func countsSpeechRightAtTheStart() {
        var detector = SpeechActivityDetector()
        let speech = detector.add(TalkFixtures.audio([true, false]))
        #expect(abs(speech - 1) < 0.001)
    }

    @Test func countsShortPausesOnceSpeechFollows() {
        var detector = SpeechActivityDetector()
        let pause = [Float](repeating: 0.001, count: 3_200)  // 200 ms
        var speech = detector.add(TalkFixtures.audio([false, true]) + pause)
        // The pause isn't counted until speech follows it.
        #expect(abs(speech - 1) < 0.001)

        speech += detector.add(TalkFixtures.audio([true]))
        #expect(abs(speech - 2.2) < 0.001)
        #expect(detector.spans.count == 1)
    }

    @Test func ignoresSteadyNoiseAndSilence() {
        var detector = SpeechActivityDetector()
        // A loud fan, as loud as speech, after the first seconds.
        let noise = [Float](repeating: 0.1, count: Int(AudioChunk.sampleRate) * 20)
        _ = detector.add([Float](repeating: 0, count: Int(AudioChunk.sampleRate) * 3))
        let speech = detector.add(noise)

        // Taken for speech only until the floor has caught up with it.
        #expect(speech <= 6.1)
        #expect(detector.spans.last.map { $0.upperBound <= 9.1 } ?? true)
    }

    @Test func keepsPartialFramesForTheNextCall() {
        var detector = SpeechActivityDetector()
        let audio = TalkFixtures.audio([false, true, false])
        var speech: TimeInterval = 0
        for start in stride(from: 0, to: audio.count, by: 333) {
            speech += detector.add(Array(audio[start..<min(start + 333, audio.count)]))
        }
        #expect(abs(speech - 1) < 0.001)
    }
}

struct TalkTimelineTests {
    @Test func splitsSpeechIntoMinutes() {
        let timeline = TalkTimeline(
            labels: SourceLabels(),
            microphone: [10..<20, 50..<70],
            systemAudio: [65..<125],
            duration: 130
        )

        #expect(timeline.minuteCount == 3)
        #expect(timeline.microphone == [20, 10, 0])
        #expect(timeline.systemAudio == [0, 55, 5])
        #expect(timeline.microphoneLabel == "Me")
        #expect(timeline.systemAudioLabel == "Others")
        #expect(timeline.total == TalkTime(microphone: 30, systemAudio: 60))
    }

    @Test func countsOverlappingSpeechOfOneKindOnce() {
        // Two microphones both hearing the user.
        let timeline = TalkTimeline(
            labels: SourceLabels(microphone: "Martin", systemAudio: " "),
            microphone: [0..<10, 5..<15, 15..<20],
            systemAudio: [],
            duration: 30
        )
        #expect(timeline.microphone == [20])
        #expect(timeline.systemAudio == [0])
        #expect(timeline.microphoneLabel == "Martin")
        #expect(timeline.systemAudioLabel == "Others")
    }

    @Test func dropsSpeechPastTheEnd() {
        let timeline = TalkTimeline(labels: SourceLabels(), microphone: [50..<200], systemAudio: [], duration: 60)
        #expect(timeline.microphone == [10])
    }

    @Test func padsTheShorterSide() {
        let timeline = TalkTimeline(
            microphoneLabel: "Me",
            systemAudioLabel: "Others",
            microphone: [1, 2],
            systemAudio: [3]
        )
        #expect(timeline.systemAudio == [3, 0])
    }

    @Test func sharesAddUpToAHundred() {
        #expect(TalkTime().microphoneShare == nil)
        #expect(TalkTime().percentages == nil)
        let talk = TalkTime(microphone: 1, systemAudio: 2)
        #expect(talk.percentages?.microphone == 33)
        #expect(talk.percentages?.systemAudio == 67)
        #expect(TalkTime(microphone: 0, systemAudio: 5).percentages?.microphone == 0)
    }
}
