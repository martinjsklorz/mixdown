import Foundation
import MixdownCore
@preconcurrency internal import MossTranscribe
import os

/// MOSS-Transcribe-Diarize (MLX). Emits its own timestamps and speaker labels in one pass per input.
///
/// The model itself accepts up to 131,072 prompt + output tokens (audio costs 12.5 tokens/s), but
/// its KV cache grows with input length (~7.7 GB FP16 for 90 min) and the call can't be cancelled
/// once started. So long recordings are cut, at silences, into windows of at most 10 minutes.
///
/// Limitation: MOSS labels speakers per call (`S01`, `S02`, …, in order of appearance), so
/// "Speaker 1" in one 10-minute window isn't necessarily "Speaker 1" in the next.
final class MossRecognizer: SpeechRecognizer, @unchecked Sendable {
    private let model: MossMLXModel

    let chunking = SpeechChunker.Configuration(
        maxWindowDuration: 600,
        // Keep silences inside a window: MOSS handles them itself, and fewer cuts mean
        // fewer places where speaker labels can reset.
        maxMergeGap: .infinity,
        padding: 0.5
    )

    /// Output budget per window. Dense speech with timestamps and speaker tags is roughly
    /// 4–5k tokens per 10 minutes; speech-swift's default of 5,120 would risk truncation.
    private static let maxTokens = 8_192

    private init(model: MossMLXModel) {
        self.model = model
    }

    static func load(
        repositoryID: String,
        cacheBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MossRecognizer {
        let directory = try ModelCache.directory(for: repositoryID, base: cacheBase)
        // Offline loads validate the whole bundle (`fromDirectory`), so a partial cache throws and
        // falls through to the online load.
        let model = try await ModelDirectory.loadPreferringCache(
            repositoryID,
            cacheLooksComplete: cacheLooksComplete(in: directory),
            progress: progress
        ) { offline, progress in
            try await MossMLXModel.fromPretrained(
                modelId: repositoryID,
                cacheDir: directory,
                offlineMode: offline,
                progressHandler: { fraction, _ in progress(fraction) }
            )
        }
        return MossRecognizer(model: model)
    }

    /// `MossMLXModel.requiredBundleFiles`, which speech-swift doesn't expose.
    static func cacheLooksComplete(in directory: URL) -> Bool {
        ModelCache.contains(
            weightsAnd: [
                "config.json", "audio_encoder.safetensors", "decoder.safetensors", "processor_config.json",
                "preprocessor_config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json",
            ],
            in: directory
        )
    }

    /// MOSS takes no language hint; it transcribes whatever it hears.
    func languageHint(forISOCode code: String) -> String? { nil }

    /// MOSS takes no vocabulary.
    func recognize(_ samples: [Float], languageHint: String?, vocabulary: [String]) throws -> [RecognizedSegment] {
        // Not cancellable once started; the engine checks between windows.
        let result = try model.transcribeDetailed(
            audio: samples,
            sampleRate: speechSampleRate,
            options: MossMLXDecodingOptions(maxTokens: Self.maxTokens)
        )
        if result.metrics.stopReason != .endOfSequence {
            transcriptionLogger.notice(
                "MOSS stopped early (\(result.metrics.stopReason.rawValue, privacy: .public)) after \(result.metrics.generatedTokens) tokens; the window's transcript may be cut short"
            )
        }
        guard !result.segments.isEmpty else {
            // Malformed structured output: `text` is then the raw decoded text. Keep it, untimed.
            return [RecognizedSegment(text: result.text)]
        }
        return result.segments.map {
            RecognizedSegment(
                text: $0.text,
                timing: TimeSpan(start: $0.startTime, end: $0.endTime),
                speaker: Self.speakerName(for: $0.speaker)
            )
        }
    }

    /// `MossMLXModel` has no `unload()`; its weights are freed with the instance.
    func unload() {}

    /// `S01` → `Speaker 1`. Unknown formats are kept as-is.
    private static func speakerName(for label: String) -> String {
        guard label.first == "S", let number = Int(label.dropFirst()) else { return label }
        return "Speaker \(number)"
    }
}
