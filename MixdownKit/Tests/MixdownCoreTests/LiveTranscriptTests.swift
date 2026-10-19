import Foundation
@testable import MixdownCore
import Testing

struct LiveTranscriptTests {
    /// Words one second apart, starting at `start`.
    private func words(_ texts: [String], from start: TimeInterval = 0) -> [LiveWord] {
        texts.enumerated().map { index, text in
            LiveWord(text: text, start: start + Double(index), end: start + Double(index) + 0.5)
        }
    }

    private func update(_ texts: [String], from start: TimeInterval = 0) -> LiveTranscriptUpdate {
        LiveTranscriptUpdate(words: words(texts, from: start))
    }

    @Test func wordsJoinOneLineUntilAPause() {
        var transcript = LiveTranscript(speakers: [nil])
        transcript.apply(update(["Hello", "there."]), fromSource: 0, startHostTime: nil)
        transcript.apply(update(["How", "are"], from: 2), fromSource: 0, startHostTime: nil)
        // 3.5 s → 6 s is longer than the pause threshold.
        transcript.apply(update(["Next", "topic."], from: 6), fromSource: 0, startHostTime: nil)

        #expect(transcript.lines.map(\.text) == ["Hello there. How are", "Next topic."])
        #expect(transcript.lines.map(\.speaker) == [nil, nil])
        #expect(transcript.lines.first?.start == 0)
        #expect(transcript.lines.first?.end == 3.5)
    }

    @Test func revisedLastWordIsReplaced() {
        var transcript = LiveTranscript(speakers: [nil])
        transcript.apply(update(["Live", "transcri"]), fromSource: 0, startHostTime: nil)
        transcript.apply(
            LiveTranscriptUpdate(
                revisesLastWord: true,
                words: [
                    LiveWord(text: "transcription.", start: 1, end: 1.8),
                    LiveWord(text: "Nice", start: 2, end: 2.5),
                ]
            ),
            fromSource: 0,
            startHostTime: nil
        )

        #expect(transcript.lines.map(\.text) == ["Live transcription. Nice"])
    }

    @Test func revisionWithoutEarlierWordsAddsTheWord() {
        var transcript = LiveTranscript(speakers: [nil])
        transcript.apply(
            LiveTranscriptUpdate(revisesLastWord: true, words: words(["Hello"])),
            fromSource: 0,
            startHostTime: nil
        )
        #expect(transcript.lines.map(\.text) == ["Hello"])
    }

    @Test func sourcesInterleaveBySpokenTimeNotArrival() {
        var transcript = LiveTranscript(speakers: ["Me", "Others"])
        // The other side's reply arrives first, though it was spoken after the microphone's words.
        transcript.apply(update(["Fine,", "thanks."], from: 3), fromSource: 1, startHostTime: nil)
        transcript.apply(update(["How", "are", "you?"]), fromSource: 0, startHostTime: nil)

        #expect(transcript.lines.map(\.speaker) == ["Me", "Others"])
        #expect(transcript.lines.map(\.text) == ["How are you?", "Fine, thanks."])

        // The microphone's line keeps growing in place: nobody else spoke in between.
        transcript.apply(update(["Good."], from: 2.6), fromSource: 0, startHostTime: nil)
        #expect(transcript.lines.map(\.text) == ["How are you? Good.", "Fine, thanks."])
    }

    @Test func otherSpeakerInBetweenStartsANewLine() {
        var transcript = LiveTranscript(speakers: ["Me", "Others"])
        transcript.apply(update(["Hello"]), fromSource: 0, startHostTime: nil)
        transcript.apply(update(["Hi"], from: 1), fromSource: 1, startHostTime: nil)
        transcript.apply(update(["again"], from: 1.5), fromSource: 0, startHostTime: nil)

        #expect(transcript.lines.map(\.text) == ["Hello", "Hi", "again"])
        #expect(transcript.lines.map(\.speaker) == ["Me", "Others", "Me"])
    }

    @Test func hostTimesLineSourcesUp() {
        var transcript = LiveTranscript(speakers: ["Me", "Others"])
        // System audio starts 5 s after the microphone, so its word at 0 s comes after the
        // microphone's at 2 s.
        transcript.apply(update(["Reply"]), fromSource: 1, startHostTime: 105)
        transcript.apply(update(["Question"], from: 2), fromSource: 0, startHostTime: 100)

        #expect(transcript.lines.map(\.text) == ["Question", "Reply"])
        #expect(transcript.lines.map(\.start) == [-3, 0])
    }

    @Test func lineIDsStayStableWhenLinesAreInserted() {
        var transcript = LiveTranscript(speakers: ["Me", "Others"])
        transcript.apply(update(["Later"], from: 5), fromSource: 1, startHostTime: nil)
        let laterID = transcript.lines[0].id
        transcript.apply(update(["Earlier"]), fromSource: 0, startHostTime: nil)

        #expect(transcript.lines.map(\.text) == ["Earlier", "Later"])
        #expect(transcript.lines[1].id == laterID)
        #expect(transcript.lines[0].id != laterID)
    }

    @Test func longLinesBreakAtSentenceEnds() {
        var transcript = LiveTranscript(speakers: [nil])
        let count = LiveTranscript.sentenceBreakWordCount
        // Words a tenth of a second apart, so no pause splits them.
        let monologue = (0..<count).map { index in
            let start = Double(index) / 10
            return LiveWord(text: index == count - 1 ? "end." : "word", start: start, end: start + 0.05)
        }
        transcript.apply(LiveTranscriptUpdate(words: monologue), fromSource: 0, startHostTime: nil)
        transcript.apply(
            LiveTranscriptUpdate(words: [LiveWord(text: "Next", start: Double(count) / 10, end: Double(count) / 10)]),
            fromSource: 0,
            startHostTime: nil
        )

        #expect(transcript.lines.count == 2)
        #expect(transcript.lines.first?.words.count == count)
        #expect(transcript.lines.last?.text == "Next")
    }

    @Test func emptyUpdatesAndUnknownSourcesAreIgnored() {
        var transcript = LiveTranscript(speakers: [nil])
        transcript.apply(LiveTranscriptUpdate(), fromSource: 0, startHostTime: 100)
        transcript.apply(update(["Hello"]), fromSource: 3, startHostTime: nil)
        #expect(transcript.isEmpty)
    }

    @Test func segmentsAreTimedFromTheirSourcesStart() {
        var transcript = LiveTranscript(speakers: ["Me", "Others"])
        // The other side started a second after the microphone.
        transcript.apply(update(["Hi", "there."], from: 0.5), fromSource: 1, startHostTime: 101)
        transcript.apply(update(["Morning."], from: 0.25), fromSource: 0, startHostTime: 100)
        transcript.apply(update(["Later."], from: 5), fromSource: 1, startHostTime: 101)

        #expect(
            transcript.segments(fromSource: 1) == [
                TranscriptSegment(start: 0.5, end: 2, text: "Hi there."),
                TranscriptSegment(start: 5, end: 5.5, text: "Later."),
            ]
        )
        #expect(transcript.segments(fromSource: 0) == [TranscriptSegment(start: 0.25, end: 0.75, text: "Morning.")])
        #expect(transcript.segments(fromSource: 2).isEmpty)
    }

    @Test func segmentsIgnoreOtherSourcesInBetween() {
        var transcript = LiveTranscript(speakers: ["Me", "Others"])
        transcript.apply(update(["Yes"], from: 0.5), fromSource: 1, startHostTime: 100)
        transcript.apply(update(["So", "the", "plan"]), fromSource: 0, startHostTime: 100)
        transcript.apply(
            LiveTranscriptUpdate(revisesLastWord: true, words: words(["plan."], from: 2)),
            fromSource: 0,
            startHostTime: 100
        )

        // On screen the other side's reply splits the microphone's words.
        #expect(transcript.lines.map(\.text) == ["So", "Yes", "the plan."])
        #expect(transcript.segments(fromSource: 0).map(\.text) == ["So the plan."])
    }

    @Test func sourcesCanBeAddedAndRelabeled() {
        var transcript = LiveTranscript(speakers: [nil])
        transcript.apply(update(["Hello."]), fromSource: 0, startHostTime: 100)
        // System audio turned on a few seconds in, which makes labels necessary.
        transcript.addSource()
        transcript.setSpeaker("Me", ofSource: 0)
        transcript.setSpeaker("Others", ofSource: 1)
        transcript.apply(update(["Hi."]), fromSource: 1, startHostTime: 104)

        #expect(transcript.lines.map(\.speaker) == ["Me", "Others"])
        #expect(transcript.lines.map(\.start) == [0, 4])
    }

    @Test func aSourceCanSwitchClocks() {
        var transcript = LiveTranscript(speakers: [nil])
        transcript.apply(update(["Before."]), fromSource: 0, startHostTime: 100)
        // A new device, recording from 10 s later, counts its times from zero again.
        transcript.apply(update(["After."]), fromSource: 0, startHostTime: 110)

        #expect(
            transcript.segments(fromSource: 0) == [
                TranscriptSegment(start: 0, end: 0.5, text: "Before."),
                TranscriptSegment(start: 10, end: 10.5, text: "After."),
            ]
        )
    }

    @Test func aBrokenSegmentKeepsTheLine() {
        var transcript = LiveTranscript(speakers: [nil])
        transcript.apply(update(["Before"]), fromSource: 0, startHostTime: 100)
        // A new device takes over a second later, within the pause threshold.
        transcript.breakSegment(ofSource: 0)
        transcript.apply(update(["after."]), fromSource: 0, startHostTime: 101)

        #expect(transcript.lines.map(\.text) == ["Before after."])
        #expect(transcript.segments(fromSource: 0).map(\.text) == ["Before", "after."])
    }

    @Test func recentWordsAreTheLastOnesAcrossLines() {
        var transcript = LiveTranscript(speakers: [nil])
        transcript.apply(update(["One", "two."]), fromSource: 0, startHostTime: nil)
        transcript.apply(update(["Three", "four", "five"], from: 6), fromSource: 0, startHostTime: nil)

        #expect(transcript.recentWords(4).map(\.text) == ["two.", "Three", "four", "five"])
        #expect(transcript.recentWords(10).map(\.text) == ["One", "two.", "Three", "four", "five"])
        #expect(transcript.recentWords(0).isEmpty)
    }

    @Test func recentWordsKeepTheirIDsAsTheLineGrows() {
        var transcript = LiveTranscript(speakers: [nil])
        transcript.apply(update(["Hello", "there"]), fromSource: 0, startHostTime: nil)
        let before = transcript.recentWords(2)
        transcript.apply(update(["again"], from: 2), fromSource: 0, startHostTime: nil)
        let after = transcript.recentWords(2)

        #expect(after.first?.id == before.last?.id)
        #expect(after.first?.text == "there")
    }

    @Test func recentWordsNameTheSpeakerWhereItChanges() {
        var transcript = LiveTranscript(speakers: ["Me", "Others"])
        transcript.apply(update(["Hello", "you"]), fromSource: 0, startHostTime: nil)
        transcript.apply(update(["Hi"], from: 2), fromSource: 1, startHostTime: nil)

        let all = transcript.recentWords(10)
        #expect(all.map(\.text) == ["Me", "Hello", "you", "Others", "Hi"])
        #expect(all.map(\.isSpeaker) == [true, false, false, true, false])
        // Without its first word, the line's speaker is left out too.
        #expect(transcript.recentWords(2).map(\.text) == ["you", "Others", "Hi"])
    }
}
