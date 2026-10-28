import Foundation
import Testing

@testable import MixdownCore

struct TextTokensTests {
    @Test func spacedTextIsSplitAtWhitespace() {
        let tokens = TextTokens.tokens(in: "Hello,  world. It's — fine")

        #expect(tokens.map(\.text) == ["Hello,", "world.", "It's", "—", "fine"])
        #expect(tokens.map(\.spaceBefore) == [false, true, true, true, true])
        #expect(tokens.map(\.weight) == [1, 1, 1, 1, 1])
    }

    @Test func unspacedScriptsAreSplitIntoCharacters() {
        let tokens = TextTokens.tokens(in: "我用iPhone拍的「照片」。 好")

        #expect(tokens.map(\.text) == ["我", "用", "iPhone", "拍", "的", "「照", "片」。", "好"])
        #expect(tokens.map(\.spaceBefore) == [false, false, false, false, false, false, false, true])
        #expect(tokens.map(\.weight) == [0.5, 0.5, 1, 0.5, 0.5, 0.5, 0.5, 0.5])
    }

    @Test func kanaWeighsLessThanChineseCharacters() {
        #expect(TextTokens.tokens(in: "です").map(\.weight) == [1.0 / 3, 1.0 / 3])
    }
}

struct UnspacedSpeakerAssignmentTests {
    @Test func aChineseSegmentIsSplitBetweenSpeakersWithoutSpaces() {
        // Ten characters with their punctuation, paced at a second per character, a sentence each.
        let segment = TranscriptSegment(start: 0, end: 23, text: "你好，我是王芳。谢谢你来。")
        // The change is a little early, within "芳。".
        let turns = [
            SpeakerTurn(start: 0, end: 12, speaker: 0),
            SpeakerTurn(start: 12, end: 23, speaker: 1),
        ]

        let labeled = SpeakerAssignment.label([segment], turns: turns)

        #expect(
            labeled == [
                TranscriptSegment(start: 0, end: 14, text: "你好，我是王芳。", speaker: "Speaker 1"),
                TranscriptSegment(start: 14, end: 23, text: "谢谢你来。", speaker: "Speaker 2"),
            ]
        )
    }

    @Test func aMinorSpeakersPiecesRejoinWithoutSpaces() {
        let first = TranscriptSegment(start: 0, end: 10, text: "我们今天讨论一下预算。")
        // A fifth of a second per character.
        let second = TranscriptSegment(start: 10, end: 14.6, text: "你好，我是王芳。谢谢你来。")
        // Speaker 1 says two words' worth of characters, in under five seconds.
        let turns = [
            SpeakerTurn(start: 0, end: 12.8, speaker: 0),
            SpeakerTurn(start: 12.8, end: 14.6, speaker: 1),
        ]

        let labeled = SpeakerAssignment.label([first, second], turns: turns)

        #expect(labeled == [first, second])
    }
}
