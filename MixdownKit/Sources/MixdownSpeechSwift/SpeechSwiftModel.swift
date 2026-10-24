import Foundation

/// The speech-swift models Mixdown can transcribe with, in two categories (`isLive`): offline
/// models transcribe the whole recording once it ends, the live one while it's recorded.
///
/// Raw values are persisted in user defaults; never change them.
public enum SpeechSwiftModel: String, CaseIterable, Sendable, Identifiable {
    /// Qwen3-ASR 0.6B on MLX. Offline; fast; no speaker labels.
    case qwen3ASRSmall = "qwen3-asr-0.6b"
    /// Qwen3-ASR 1.7B on MLX. Offline; more accurate, roughly twice as slow; no speaker labels.
    case qwen3ASRLarge = "qwen3-asr-1.7b"
    /// MOSS-Transcribe-Diarize 0.9B on MLX. Offline; timestamped transcript with speaker labels.
    case mossTranscribeDiarize = "moss-diarize"
    /// Cohere Transcribe 2B on MLX. Offline; accurate, in 14 languages; no speaker labels. Doesn't
    /// detect the language.
    case cohereTranscribe = "cohere-transcribe-2b"
    /// Nemotron-3.5 ASR Streaming 0.6B on MLX. Live: transcribes while recording, so no audio is
    /// kept; no speaker labels beyond the input.
    case nemotronStreaming = "nemotron-streaming-0.6b"

    public static var `default`: SpeechSwiftModel { .nemotronStreaming }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qwen3ASRSmall: "Qwen3-ASR 0.6B"
        case .qwen3ASRLarge: "Qwen3-ASR 1.7B"
        case .mossTranscribeDiarize: "MOSS Transcribe Diarize 0.9B"
        case .cohereTranscribe: "Cohere Transcribe 2B"
        case .nemotronStreaming: "Nemotron 3.5 ASR Streaming 0.6B"
        }
    }

    /// What the model is chosen for within its category.
    public var purpose: String {
        switch self {
        case .qwen3ASRSmall: "Low"
        case .qwen3ASRLarge: "High"
        case .mossTranscribeDiarize: "Speakers"
        case .cohereTranscribe: "Accuracy"
        case .nemotronStreaming: "Live"
        }
    }

    /// Whether the model transcribes while recording rather than once the recording ends.
    public var isLive: Bool { self == .nemotronStreaming }

    /// Whether `TranscriptionOptions.language` is honored. Otherwise the language is auto-detected.
    public var supportsLanguageSelection: Bool {
        switch self {
        case .qwen3ASRSmall, .qwen3ASRLarge, .cohereTranscribe, .nemotronStreaming: true
        case .mossTranscribeDiarize: false
        }
    }

    /// Whether transcript segments carry speaker labels.
    public var labelsSpeakers: Bool {
        switch self {
        case .qwen3ASRSmall, .qwen3ASRLarge, .cohereTranscribe, .nemotronStreaming: false
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
        // INT8 rather than speech-swift's INT5 default: FP16's WER (6.18% vs 6.29% on FLEURS
        // English) for ~650 MB more RAM (docs/benchmarks/cohere-voxtral-asr.md).
        case .cohereTranscribe: "aufklarer/Cohere-Transcribe-2B-MLX-8bit"
        case .nemotronStreaming: LiveRecognizer.repositoryID
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
        // INT8 measured 65.7× on an M5 Pro, on short utterances (docs/benchmarks/cohere-voxtral-asr.md).
        case .cohereTranscribe: 20
        // Unused: the live model keeps up with the recording, so there's nothing to estimate.
        case .nemotronStreaming: 20
        }
    }

    /// The backend that loads and runs an offline model; `nil` for the live one, which
    /// `LiveRecognizer` runs.
    var recognizerType: (any SpeechRecognizer.Type)? {
        switch self {
        case .qwen3ASRSmall, .qwen3ASRLarge: Qwen3Recognizer.self
        case .mossTranscribeDiarize: MossRecognizer.self
        case .cohereTranscribe: CohereRecognizer.self
        case .nemotronStreaming: nil
        }
    }
}
