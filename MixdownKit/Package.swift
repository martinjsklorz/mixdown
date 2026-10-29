// swift-tools-version: 6.2
import PackageDescription

/// For every target of ours: a warning fails the build, so none pile up unnoticed. Dependencies
/// keep their own settings.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "MixdownKit",
    // macOS 26 for Apple's speech model (`SpeechAnalyzer`) and Foundation Models, so neither needs
    // availability checks; only their macOS 27 additions do.
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MixdownCore", targets: ["MixdownCore"]),
        .library(name: "MixdownAudio", targets: ["MixdownAudio"]),
        .library(name: "MixdownSpeechSwift", targets: ["MixdownSpeechSwift"]),
        .library(name: "MixdownAppleSpeech", targets: ["MixdownAppleSpeech"]),
        .library(name: "MixdownFoundationModels", targets: ["MixdownFoundationModels"]),
        .library(name: "MixdownMLXLLM", targets: ["MixdownMLXLLM"]),
        .library(name: "MixdownAppleTranslation", targets: ["MixdownAppleTranslation"]),
        .library(name: "MixdownNaturalLanguage", targets: ["MixdownNaturalLanguage"]),
        .library(name: "MixdownNotes", targets: ["MixdownNotes"]),
    ],
    dependencies: [
        // Pre-1.0 and its API still moves between releases, so pin exactly and bump deliberately.
        .package(url: "https://github.com/soniqo/speech-swift.git", exact: "0.0.28"),
        // Only for `Memory.clearCache()` after unloading a model. speech-swift's requirement
        // (and mlx-swift-lm's pin) decides the version; this one just has to allow it.
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.30.0"),
        // Language models on MLX, for summaries. speech-swift pins it exactly, which decides the
        // version; this one just has to allow it.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.0"),
        // Tokenizers and chat templates for mlx-swift-lm, which leaves the choice to the app.
        // speech-swift's requirement decides the version here too.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6"),
    ],
    targets: [
        // Domain models and protocols. No third-party dependencies, no platform frameworks
        // beyond Foundation/Observation, so every other module can depend on it.
        .target(name: "MixdownCore", swiftSettings: strict),

        // Microphone (Core Audio IO proc) and system audio (Core Audio process tap) capture,
        // which other apps are recording (for call detection), and reading audio files to import.
        .target(name: "MixdownAudio", dependencies: ["MixdownCore"], swiftSettings: strict),

        // speech-swift (MLX) implementation of `TranscriptionEngine`, and its LocalVQE echo
        // canceller (`EchoCancellation`). The only module that knows about speech-swift, so either
        // can be replaced without touching the rest.
        .target(
            name: "MixdownSpeechSwift",
            dependencies: [
                "MixdownCore",
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "CohereTranscribeASR", package: "speech-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MossTranscribe", package: "speech-swift"),
                .product(name: "NemotronStreamingASR", package: "speech-swift"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "SpeechEnhancement", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
            ],
            swiftSettings: strict
        ),

        // Speech framework (`SpeechAnalyzer`) implementation of `TranscriptionEngine`: Apple's
        // on-device speech model, which macOS downloads and keeps up to date.
        .target(name: "MixdownAppleSpeech", dependencies: ["MixdownCore"], swiftSettings: strict),

        // Foundation Models (Apple Intelligence) implementation of `Summarizer` and `NoteAnswerer`.
        // The only module that knows about FoundationModels, so summaries can come from elsewhere
        // too.
        .target(
            name: "MixdownFoundationModels",
            dependencies: ["MixdownCore", "MixdownNaturalLanguage"],
            swiftSettings: strict
        ),

        // mlx-swift-lm implementation of `Summarizer`: open models such as Qwen3, downloaded from
        // Hugging Face with speech-swift's downloader into the speech models' folder. The only
        // module that knows about mlx-swift-lm.
        .target(
            name: "MixdownMLXLLM",
            dependencies: [
                "MixdownCore",
                "MixdownNaturalLanguage",
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: strict
        ),

        // Translation framework implementation of `Translator`: Apple's on-device translation
        // models, which macOS downloads per language. Tells which language a transcript is in with
        // MixdownNaturalLanguage.
        .target(
            name: "MixdownAppleTranslation",
            dependencies: ["MixdownCore", "MixdownNaturalLanguage"],
            swiftSettings: strict
        ),

        // NaturalLanguage implementation of `TextEmbedder`: Apple's on-device contextual
        // embedding models, which macOS downloads per script, for finding notes to answer from.
        // Also tells summarizers which language a transcript is in.
        .target(name: "MixdownNaturalLanguage", dependencies: ["MixdownCore"], swiftSettings: strict),

        // Markdown rendering and persistence of notes, and finding what Chat answers from.
        .target(name: "MixdownNotes", dependencies: ["MixdownCore"], swiftSettings: strict),

        .testTarget(name: "MixdownCoreTests", dependencies: ["MixdownCore"], swiftSettings: strict),
        .testTarget(name: "MixdownAudioTests", dependencies: ["MixdownAudio"], swiftSettings: strict),
        .testTarget(name: "MixdownNotesTests", dependencies: ["MixdownNotes"], swiftSettings: strict),
        .testTarget(name: "MixdownSpeechSwiftTests", dependencies: ["MixdownSpeechSwift"], swiftSettings: strict),
        .testTarget(name: "MixdownAppleSpeechTests", dependencies: ["MixdownAppleSpeech"], swiftSettings: strict),
        .testTarget(name: "MixdownMLXLLMTests", dependencies: ["MixdownMLXLLM"], swiftSettings: strict),
        .testTarget(
            name: "MixdownFoundationModelsTests",
            dependencies: ["MixdownFoundationModels"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "MixdownNaturalLanguageTests",
            dependencies: ["MixdownNaturalLanguage"],
            swiftSettings: strict
        ),
    ]
)
