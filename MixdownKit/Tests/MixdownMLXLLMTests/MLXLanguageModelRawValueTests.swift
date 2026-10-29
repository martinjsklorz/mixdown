import MixdownMLXLLM
import Testing

/// The raw values are stored in user defaults, behind "mlx-", as the chosen summary model.
/// Changing one silently resets everyone who chose it to the default.
struct MLXLanguageModelRawValueTests {
    @Test func rawValuesNeverChange() {
        #expect(
            MLXLanguageModel.allCases.map(\.rawValue) == [
                "qwen3-1.7b", "qwen3-4b-instruct-2507", "qwen3.5-4b", "qwen3-8b",
            ]
        )
    }

    @Test func rawValuesRoundTrip() {
        for model in MLXLanguageModel.allCases {
            #expect(MLXLanguageModel(rawValue: model.rawValue) == model)
        }
        #expect(MLXLanguageModel(rawValue: "apple-intelligence") == nil)
    }
}
