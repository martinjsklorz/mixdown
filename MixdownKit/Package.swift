// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MixdownKit",
    // macOS 26 for Apple's speech model (`SpeechAnalyzer`) and Foundation Models, so neither needs
    // availability checks; only their macOS 27 additions do. A string, as this tools version has no
    // `.v26`.
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MixdownCore", targets: ["MixdownCore"]),
        .library(name: "MixdownAudio", targets: ["MixdownAudio"]),
        .library(name: "MixdownSpeechSwift", targets: ["MixdownSpeechSwift"]),
        .library(name: "MixdownAppleSpeech", targets: ["MixdownAppleSpeech"]),
        .library(name: "MixdownFoundationModels", targets: ["MixdownFoundationModels"]),
        .library(name: "MixdownNotes", targets: ["MixdownNotes"]),
    ],
    dependencies: [
        // Pre-1.0 and its API still moves between releases, so pin exactly and bump deliberately.
        .package(url: "https://github.com/soniqo/speech-swift.git", exact: "0.0.28"),
        // Only for `Memory.clearCache()` after unloading a model. speech-swift's requirement
        // (and mlx-swift-lm's pin) decides the version; this one just has to allow it.
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.30.0"),
    ],
    targets: [
        // Domain models and protocols. No third-party dependencies, no platform frameworks
        // beyond Foundation/Observation, so every other module can depend on it.
        .target(name: "MixdownCore"),

        // Microphone (Core Audio IO proc) and system audio (Core Audio process tap) capture, and
        // which other apps are recording (for call detection).
        .target(name: "MixdownAudio", dependencies: ["MixdownCore"]),

        // speech-swift (MLX) implementation of `TranscriptionEngine`. The only module that
        // knows about speech-swift, so the engine can be replaced without touching the rest.
        .target(
            name: "MixdownSpeechSwift",
            dependencies: [
                "MixdownCore",
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MossTranscribe", package: "speech-swift"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
            ]
        ),

        // Speech framework (`SpeechAnalyzer`) implementation of `TranscriptionEngine`: Apple's
        // on-device speech model, which macOS downloads and keeps up to date.
        .target(name: "MixdownAppleSpeech", dependencies: ["MixdownCore"]),

        // Foundation Models (Apple Intelligence) implementation of `Summarizer`. The only module
        // that knows about FoundationModels, so summaries can come from elsewhere too.
        .target(name: "MixdownFoundationModels", dependencies: ["MixdownCore"]),

        // Markdown rendering and persistence of notes.
        .target(name: "MixdownNotes", dependencies: ["MixdownCore"]),

        .testTarget(name: "MixdownCoreTests", dependencies: ["MixdownCore"]),
        .testTarget(name: "MixdownNotesTests", dependencies: ["MixdownNotes"]),
        .testTarget(name: "MixdownSpeechSwiftTests", dependencies: ["MixdownSpeechSwift"]),
    ]
)
