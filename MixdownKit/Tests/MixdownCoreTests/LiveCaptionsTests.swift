import Foundation
import Testing

@testable import MixdownCore

struct LiveCaptionsTests {
    /// Words one second apart, starting at `start`.
    private func update(_ texts: [String], from start: TimeInterval = 0) -> LiveTranscriptUpdate {
        LiveTranscriptUpdate(
            words: texts.enumerated().map { index, text in
                LiveWord(text: text, start: start + Double(index), end: start + Double(index) + 0.5)
            }
        )
    }

    @Test func linesAreTranslatedAgainOnceTheyGrow() throws {
        var transcript = LiveTranscript(speakers: [nil])
        transcript.apply(update(["Good", "morning", "everyone"]), fromSource: 0, startHostTime: nil)
        var captions = LiveCaptions(language: "de")

        let line = try #require(captions.linesToTranslate(in: transcript).first)
        captions.setTranslation("Guten Morgen allerseits", of: line.text, forLine: line.id)
        #expect(captions.linesToTranslate(in: transcript).isEmpty)
        #expect(captions.translation(of: line) == "Guten Morgen allerseits")

        transcript.apply(update(["and"], from: 3), fromSource: 0, startHostTime: nil)
        let grown = try #require(transcript.lines.first)
        #expect(captions.linesToTranslate(in: transcript).map(\.text) == ["Good morning everyone and"])
        // Until then, the line keeps the translation it has.
        #expect(captions.translation(of: grown) == "Guten Morgen allerseits")
    }

    @Test func shortLinesWaitUntilTheyEnd() {
        var transcript = LiveTranscript(speakers: ["Me", "Others"])
        transcript.apply(update(["Yes."]), fromSource: 0, startHostTime: nil)
        let captions = LiveCaptions(language: "de")
        // Too short to tell its language while it may still grow.
        #expect(captions.linesToTranslate(in: transcript).isEmpty)

        transcript.apply(update(["Okay"], from: 1), fromSource: 1, startHostTime: nil)
        #expect(captions.linesToTranslate(in: transcript).map(\.text) == ["Yes."])
    }

    @Test func failedLinesWaitUntilTheyGrow() throws {
        var transcript = LiveTranscript(speakers: [nil])
        transcript.apply(update(["Bonjour", "tout", "le"]), fromSource: 0, startHostTime: nil)
        var captions = LiveCaptions(language: "de")
        let line = try #require(transcript.lines.first)

        captions.setFailure(of: line.text, forLine: line.id, problem: "Download French")
        #expect(captions.problem == "Download French")
        #expect(captions.linesToTranslate(in: transcript).isEmpty)
        // Shown as it is.
        #expect(captions.recentWords(10, of: transcript).map(\.text) == ["Bonjour", "tout", "le"])

        transcript.apply(update(["monde."], from: 3), fromSource: 0, startHostTime: nil)
        let grown = try #require(transcript.lines.first)
        #expect(captions.linesToTranslate(in: transcript) == [grown])
        captions.setTranslation("Hallo zusammen.", of: grown.text, forLine: grown.id)
        #expect(captions.problem == nil)
    }

    @Test func recentWordsAreTranslatedAndLeaveOutLinesNotTranslatedYet() throws {
        var transcript = LiveTranscript(speakers: ["Me", "Others"])
        transcript.apply(update(["Wie", "geht's", "euch?"]), fromSource: 0, startHostTime: nil)
        transcript.apply(update(["Very", "well,", "thanks."], from: 3), fromSource: 1, startHostTime: nil)
        transcript.apply(update(["Und", "sonst", "so?"], from: 6), fromSource: 0, startHostTime: nil)
        var captions = LiveCaptions(language: "de")
        let lines = transcript.lines

        // Already in German.
        captions.setTranslation(nil, of: lines[0].text, forLine: lines[0].id)
        captions.setTranslation("Sehr gut, danke.", of: lines[1].text, forLine: lines[1].id)

        let words = captions.recentWords(20, of: transcript)
        #expect(words.map(\.text) == ["Me", "Wie", "geht's", "euch?", "Others", "Sehr", "gut,", "danke."])
        #expect(captions.recentWords(2, of: transcript).map(\.text) == ["gut,", "danke."])
    }
}
