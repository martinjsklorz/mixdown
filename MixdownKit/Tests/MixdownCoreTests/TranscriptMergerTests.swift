import Foundation
@testable import MixdownCore
import Testing

struct TranscriptMergerTests {
    private func source(
        _ device: AudioInputDevice,
        _ label: String,
        _ segments: [TranscriptSegment],
        language: String? = nil
    ) -> SourceTranscript {
        SourceTranscript(device: device, label: label, transcript: Transcript(segments: segments, language: language))
    }

    @Test func interleavesSourcesByStartTime() {
        let merged = TranscriptMerger.merge([
            source(
                Fixtures.builtInMic,
                "Me",
                [
                    TranscriptSegment(start: 0, end: 2, text: "Morning, everyone."),
                    TranscriptSegment(start: 6, end: 8, text: "Sounds good to me."),
                ]
            ),
            source(
                .systemAudio,
                "Others",
                [
                    TranscriptSegment(start: 3, end: 5, text: "Let's look at the release plan.")
                ],
                language: "en"
            ),
        ])

        #expect(
            merged.segments.map(\.text) == [
                "Morning, everyone.", "Let's look at the release plan.", "Sounds good to me.",
            ]
        )
        #expect(merged.speakers == ["Me", "Others"])
        #expect(merged.language == "en")
    }

    @Test func keepsSpeakerNumbersWithinEachSource() {
        let merged = TranscriptMerger.merge([
            source(
                Fixtures.builtInMic,
                "Me",
                [
                    TranscriptSegment(start: 0, end: 1, text: "Hi.", speaker: "Speaker 1")
                ]
            ),
            source(
                .systemAudio,
                "Others",
                [
                    TranscriptSegment(start: 2, end: 3, text: "Hello.", speaker: "Speaker 1"),
                    TranscriptSegment(start: 4, end: 5, text: "Hey!", speaker: "Speaker 2"),
                ]
            ),
        ])
        #expect(merged.speakers == ["Me (Speaker 1)", "Others (Speaker 1)", "Others (Speaker 2)"])
    }

    @Test func dropsMicrophoneEchoOfSystemAudio() {
        let merged = TranscriptMerger.merge([
            source(
                Fixtures.builtInMic,
                "Me",
                [
                    // Picked up from the speakers, slightly garbled and late.
                    TranscriptSegment(start: 3.4, end: 5.2, text: "let's look at the release plan"),
                    // The user talking over the end of it.
                    TranscriptSegment(start: 5, end: 7, text: "Wait, which release?"),
                ]
            ),
            source(
                .systemAudio,
                "Others",
                [
                    TranscriptSegment(start: 3, end: 5, text: "Let's look at the release plan.")
                ]
            ),
        ])
        #expect(merged.segments.map(\.speaker) == ["Others", "Me"])
        #expect(merged.segments.last?.text == "Wait, which release?")
    }

    @Test func keepsSimilarSpeechAtOtherTimes() {
        let segment = TranscriptSegment(start: 30, end: 32, text: "Let's look at the release plan.")
        let reference = [TranscriptSegment(start: 3, end: 5, text: "Let's look at the release plan.")]
        #expect(!TranscriptMerger.isEcho(segment, of: reference))
    }

    @Test func echoNeedsMostWordsToMatch() {
        let reference = [TranscriptSegment(start: 0, end: 4, text: "We ship the beta on Friday.")]
        let partial = TranscriptSegment(start: 1, end: 3, text: "I think we should not ship on Friday")
        let echo = TranscriptSegment(start: 1, end: 3, text: "we ship the beta friday")
        #expect(!TranscriptMerger.isEcho(partial, of: reference))
        #expect(TranscriptMerger.isEcho(echo, of: reference))
    }

    @Test func keepsShortRepliesDuringLongSystemSpeech() {
        let merged = TranscriptMerger.merge([
            source(
                Fixtures.builtInMic,
                "Me",
                [
                    TranscriptSegment(start: 4, end: 4.5, text: "Yes."),
                    TranscriptSegment(start: 9, end: 10.5, text: "No, we should not."),
                ]
            ),
            source(
                .systemAudio,
                "Others",
                [
                    TranscriptSegment(
                        start: 0,
                        end: 14,
                        text: "Yes, so no matter what we decide, we should not ship before the review is done."
                    )
                ]
            ),
        ])
        #expect(
            merged.segments.map(\.text) == [
                "Yes, so no matter what we decide, we should not ship before the review is done.",
                "Yes.",
                "No, we should not.",
            ]
        )
    }

    @Test func echoNeedsFourWords() {
        let reference = [TranscriptSegment(start: 0, end: 1, text: "Sounds good to me.")]
        #expect(!TranscriptMerger.isEcho(TranscriptSegment(start: 0, end: 1, text: "Sounds good."), of: reference))
        #expect(TranscriptMerger.isEcho(TranscriptSegment(start: 0, end: 1, text: "sounds good to me"), of: reference))
    }

    @Test func contractionsCountAsOneWord() {
        #expect(TranscriptMerger.normalizedWords("It’s fine, let's go.") == ["its", "fine", "lets", "go"])
    }

    @Test func echoNeedsWordsInTheSameOrder() {
        let reference = [TranscriptSegment(start: 0, end: 3, text: "We should ship it, not later.")]
        let reply = TranscriptSegment(start: 0, end: 3, text: "Should we not ship it?")
        #expect(!TranscriptMerger.isEcho(reply, of: reference))
    }

    @Test func echoNeedsMostOfBothSegmentsToOverlap() {
        let reference = [TranscriptSegment(start: 0, end: 6, text: "Let's look at the release plan.")]
        let late = TranscriptSegment(start: 4, end: 7, text: "let's look at the release plan")
        let lagging = TranscriptSegment(start: 0.4, end: 6.3, text: "let's look at the release plan")
        #expect(!TranscriptMerger.isEcho(late, of: reference))
        #expect(TranscriptMerger.isEcho(lagging, of: reference))
    }

    @Test func labelsFallBackAndDisambiguateMicrophones() {
        let labels = SourceLabels(microphone: "  ", systemAudio: "Team")
        #expect(labels.label(for: Fixtures.builtInMic, among: [Fixtures.builtInMic, .systemAudio]) == "Me")
        #expect(labels.label(for: .systemAudio, among: [Fixtures.builtInMic, .systemAudio]) == "Team")
        #expect(
            labels.label(for: Fixtures.usbMic, among: [Fixtures.usbMic, Fixtures.builtInMic])
                == "Me (USB Microphone)"
        )
    }
}
