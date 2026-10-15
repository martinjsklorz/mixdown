// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MixdownKit",
    // macOS 15 is speech-swift's minimum (its CoreML pipelines use MLState).
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MixdownCore", targets: ["MixdownCore"]),
        .library(name: "MixdownAudio", targets: ["MixdownAudio"]),
        .library(name: "MixdownSpeechSwift", targets: ["MixdownSpeechSwift"]),
        .library(name: "MixdownFoundationModels", targets: ["MixdownFoundationModels"]),
        .library(name: "MixdownNotes", targets: ["MixdownNotes"]),
    ],
    dependencies: [
        // Pre-1.0 and its API still moves between releases, so pin exactly and bump deliberately.
        .package(url: "https://github.com/soniqo/speech-swift.git", exact: "0.0.28"),
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
                .product(name: "MossTranscribe", package: "speech-swift"),
                .product(name: "NemotronStreamingASR", package: "speech-swift"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
            ]
        ),

        // Foundation Models (Apple Intelligence) implementation of `Summarizer`. The only module
        // that knows about FoundationModels, so summaries can come from elsewhere too.
        .target(
            name: "MixdownFoundationModels",
            dependencies: ["MixdownCore"],
            // FoundationModels ships with macOS 26. Weak linking lets the app still launch on
            // macOS 15, where the summarizer reports itself unavailable instead.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])]
        ),

        // Markdown rendering and persistence of notes.
        .target(name: "MixdownNotes", dependencies: ["MixdownCore"]),

        .testTarget(name: "MixdownCoreTests", dependencies: ["MixdownCore"]),
        .testTarget(name: "MixdownNotesTests", dependencies: ["MixdownNotes"]),
        .testTarget(name: "MixdownSpeechSwiftTests", dependencies: ["MixdownSpeechSwift"]),
    ]
)
