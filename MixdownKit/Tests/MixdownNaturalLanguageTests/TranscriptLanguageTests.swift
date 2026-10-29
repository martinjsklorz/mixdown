import MixdownCore
import MixdownNaturalLanguage
import Testing

struct TranscriptLanguageTests {
    private func transcript(_ text: String, language: String? = nil) -> Transcript {
        Transcript(segments: [TranscriptSegment(start: 0, end: 5, text: text)], language: language)
    }

    @Test func detectsTheLanguageOfTheText() {
        #expect(TranscriptLanguage.code(of: "We agreed to ship the release on Friday after the review.") == "en")
        #expect(
            TranscriptLanguage.code(of: "Wir haben vereinbart, das Release am Freitag nach dem Review auszuliefern.")
                == "de"
        )
    }

    @Test func prefersTheLanguageTheTranscriptWasMadeIn() {
        #expect(TranscriptLanguage.code(of: transcript("We agreed to ship on Friday.", language: "de")) == "de")
    }

    @Test func anEmptyLanguageFallsBackToDetection() {
        #expect(
            TranscriptLanguage.code(of: transcript("We agreed to ship the release on Friday.", language: "")) == "en"
        )
    }

    @Test func nothingBelowTheConfidenceAskedFor() {
        #expect(TranscriptLanguage.code(of: "ok", minimumConfidence: 1) == nil)
        #expect(TranscriptLanguage.code(of: "") == nil)
    }
}
