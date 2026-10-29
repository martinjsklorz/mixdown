import MixdownSpeechSwift
import Testing

/// The raw values are stored in user defaults as the chosen transcription model. Changing one
/// silently resets everyone who chose it to the default.
struct SpeechSwiftModelRawValueTests {
    @Test func rawValuesNeverChange() {
        #expect(
            SpeechSwiftModel.allCases.map(\.rawValue) == [
                "qwen3-asr-0.6b", "qwen3-asr-1.7b", "moss-diarize", "cohere-transcribe-2b", "nemotron-streaming-0.6b",
            ]
        )
    }

    /// The app stores Apple's speech model as "apple-speech" in the same setting.
    @Test func noRawValueClashesWithApplesModel() {
        #expect(SpeechSwiftModel(rawValue: "apple-speech") == nil)
    }
}
