import MixdownCore
import Testing

@testable import MixdownSpeechSwift

struct LiveWordDiffTests {
    private func words(_ texts: String...) -> [LiveWord] {
        texts.enumerated().map { LiveWord(text: $1, start: Double($0), end: Double($0) + 0.5) }
    }

    @Test func reportsAppendedWords() {
        var diff = LiveWordDiff()

        #expect(diff.update(words("Hello")) == LiveTranscriptUpdate(words: words("Hello")))
        #expect(diff.update(words("Hello", "there")) == LiveTranscriptUpdate(words: [words("Hello", "there")[1]]))
    }

    @Test func revisesTheLastWordWhileItGrows() {
        var diff = LiveWordDiff()
        _ = diff.update(words("We", "transcri"))

        let update = diff.update(words("We", "transcription.", "Next"))

        #expect(
            update
                == LiveTranscriptUpdate(
                    revisesLastWord: true,
                    words: Array(words("We", "transcription.", "Next")[1...])
                )
        )
    }

    @Test func unchangedWordsGiveAnEmptyUpdate() {
        var diff = LiveWordDiff()
        _ = diff.update(words("Hello", "there"))

        #expect(diff.update(words("Hello", "there")).isEmpty)
    }

    @Test func keepsReportingAfterTheListShrinks() {
        var diff = LiveWordDiff()
        _ = diff.update(words("A", "b", "c"))

        // Re-segmented into fewer words: what was reported stays.
        #expect(diff.update(words("A", "bc")).isEmpty)
        // Words after that are diffed against the shorter list, so none are lost.
        #expect(diff.update(words("A", "bc", "d")) == LiveTranscriptUpdate(words: [words("A", "bc", "d")[2]]))
        #expect(
            diff.update(words("A", "bc", "de"))
                == LiveTranscriptUpdate(revisesLastWord: true, words: [words("A", "bc", "de")[2]])
        )
    }
}
