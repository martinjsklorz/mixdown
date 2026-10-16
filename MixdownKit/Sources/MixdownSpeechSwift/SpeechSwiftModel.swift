import Foundation

/// The speech-swift models Mixdown can transcribe with.
///
/// Raw values are persisted in user defaults; never change them.
public enum SpeechSwiftModel: String, CaseIterable, Sendable, Identifiable {
    /// Qwen3-ASR 0.6B on MLX. Fast; no speaker labels.
    case qwen3ASRSmall = "qwen3-asr-0.6b"
    /// Qwen3-ASR 1.7B on MLX. More accurate, roughly twice as slow; no speaker labels.
    case qwen3ASRLarge = "qwen3-asr-1.7b"
    /// MOSS-Transcribe-Diarize 0.9B on MLX. Timestamped transcript with speaker labels.
    case mossTranscribeDiarize = "moss-diarize"

    public static var `default`: SpeechSwiftModel { .qwen3ASRSmall }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qwen3ASRSmall: "Qwen3-ASR 0.6B (fast)"
        case .qwen3ASRLarge: "Qwen3-ASR 1.7B (accurate)"
        case .mossTranscribeDiarize: "MOSS Transcribe Diarize 0.9B (speakers)"
        }
    }

    /// Whether `TranscriptionOptions.language` is honored. Otherwise the language is auto-detected.
    public var supportsLanguageSelection: Bool {
        switch self {
        case .qwen3ASRSmall, .qwen3ASRLarge: true
        case .mossTranscribeDiarize: false
        }
    }

    /// Whether transcript segments carry speaker labels.
    public var labelsSpeakers: Bool {
        switch self {
        case .qwen3ASRSmall, .qwen3ASRLarge: false
        case .mossTranscribeDiarize: true
        }
    }
}

extension SpeechSwiftModel {
    /// Hugging Face repository with the weights. Changing it triggers a fresh download.
    var repositoryID: String {
        switch self {
        // 8-bit rather than speech-swift's 4-bit default: 1.65% vs 2.33% WER on LibriSpeech
        // for ~300 MB more RAM (docs/models/asr-model.md).
        case .qwen3ASRSmall: "aufklarer/Qwen3-ASR-0.6B-MLX-8bit"
        case .qwen3ASRLarge: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
        // INT5 is speech-swift's recommended MOSS MLX variant (docs/benchmarks/moss-mlx.md).
        case .mossTranscribeDiarize: "aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-5bit"
        }
    }

    /// Seconds of audio a piece takes per second of recognition, for the progress estimate until
    /// the engine has timed this Mac. On the slow side, so the first estimate doesn't overshoot.
    /// MOSS INT5 measured 15.5× with diarization on an M5 Pro (docs/benchmarks/moss-mlx.md).
    var expectedSpeed: Double {
        switch self {
        case .qwen3ASRSmall: 20
        case .qwen3ASRLarge: 10
        case .mossTranscribeDiarize: 6
        }
    }

    /// The backend that loads and runs this model.
    var recognizerType: any SpeechRecognizer.Type {
        switch self {
        case .qwen3ASRSmall, .qwen3ASRLarge: Qwen3Recognizer.self
        case .mossTranscribeDiarize: MossRecognizer.self
        }
    }
}
