import Testing

@testable import MixdownSpeechSwift

struct Qwen3VocabularyTests {
    @Test func contextListsTheTermsUpToTheMaximum() {
        #expect(Qwen3Recognizer.context(for: []) == nil)
        #expect(Qwen3Recognizer.context(for: ["Kubernetes", "Acme Corp"]) == "Kubernetes, Acme Corp")
        let many = (0..<150).map { "Term\($0)" }
        let context = Qwen3Recognizer.context(for: many)
        #expect(context?.split(separator: ",").count == Qwen3Recognizer.maximumContextTerms)
    }

    @Test func textOfOnlyVocabularyWordsMayBeMadeUp() {
        let vocabulary = ["Kubernetes", "Acme Corp"]
        #expect(Qwen3Recognizer.mayBeMadeUp("", from: vocabulary))
        #expect(Qwen3Recognizer.mayBeMadeUp("Kubernetes, Acme Corp.", from: vocabulary))
        // One word can well be what was said.
        #expect(!Qwen3Recognizer.mayBeMadeUp("Kubernetes.", from: vocabulary))
        #expect(!Qwen3Recognizer.mayBeMadeUp("We moved Acme Corp to Kubernetes.", from: vocabulary))
    }
}
