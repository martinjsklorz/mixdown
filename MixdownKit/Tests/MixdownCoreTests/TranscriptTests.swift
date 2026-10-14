import MixdownCore
import Testing

struct TranscriptTests {
    @Test func textTrimsAndJoinsSegments() {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 1, text: "  Hello "),
            TranscriptSegment(start: 1, end: 2, text: ""),
            TranscriptSegment(start: 2, end: 3, text: " \n "),
            TranscriptSegment(start: 3, end: 4, text: "world.\n"),
        ])
        #expect(transcript.text == "Hello world.")
        #expect(!transcript.isEmpty)
    }

    @Test func whitespaceOnlyTranscriptIsEmpty() {
        #expect(Transcript(segments: []).isEmpty)
        #expect(Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "   ")]).isEmpty)
    }

    @Test func speakersAreDistinctInOrderOfAppearance() {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 1, text: "a", speaker: "Speaker 2"),
            TranscriptSegment(start: 1, end: 2, text: "b"),
            TranscriptSegment(start: 2, end: 3, text: "c", speaker: "Speaker 1"),
            TranscriptSegment(start: 3, end: 4, text: "d", speaker: "Speaker 2"),
        ])
        #expect(transcript.speakers == ["Speaker 2", "Speaker 1"])
        #expect(Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "x")]).speakers.isEmpty)
    }
}
