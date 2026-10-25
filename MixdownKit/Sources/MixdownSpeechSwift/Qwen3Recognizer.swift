import Foundation
import MixdownCore
@preconcurrency internal import Qwen3ASR

/// Qwen3-ASR (MLX). Plain text, no timestamps, so the engine feeds it short VAD pieces.
final class Qwen3Recognizer: SpeechRecognizer, @unchecked Sendable {
    private let model: Qwen3ASRModel

    /// `Qwen3ASRModel.transcribe` switches from the greedy fast path to a slower n-gram-blocking
    /// decoder above `Qwen3DecodingOptions.longInputThresholdSeconds` (15 s), and caps output at
    /// 448 tokens per call. speech-swift's own `StreamingASR` cuts at 10 s. Pieces of at most 14 s
    /// stay on the fast path with plenty of token headroom.
    let chunking = SpeechChunker.Configuration(maxWindowDuration: 14, maxMergeGap: 0.8, padding: 0.25)

    private init(model: Qwen3ASRModel) {
        self.model = model
    }

    static func load(
        repositoryID: String,
        cacheBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Qwen3Recognizer {
        let directory = try ModelCache.directory(for: repositoryID, base: cacheBase)
        let model = try await ModelDirectory.loadPreferringCache(
            repositoryID,
            cacheLooksComplete: cacheLooksComplete(in: directory),
            progress: progress
        ) { offline, progress in
            try await Qwen3ASRModel.fromPretrained(
                modelId: repositoryID,
                cacheDir: directory,
                offlineMode: offline,
                progressHandler: { fraction, _ in progress(fraction) }
            )
        }
        return Qwen3Recognizer(model: model)
    }

    /// `fromPretrained` checks only for weights when offline and silently loads without a tokenizer
    /// if vocab.json is missing (it then returns token IDs as text), so require the tokenizer files too.
    static func cacheLooksComplete(in directory: URL) -> Bool {
        ModelCache.contains(weightsAnd: ["vocab.json", "merges.txt"], in: directory)
    }

    func languageHint(forISOCode code: String) -> String? {
        Self.languageNames[code]
    }

    /// The vocabulary goes into the prompt as context, which makes the model write those words as
    /// they're spelled there. A piece that then comes out empty, or as nothing but words from the
    /// context, is transcribed again without it, in case the model made it up from the context.
    func recognize(_ samples: [Float], languageHint: String?, vocabulary: [String]) throws -> [RecognizedSegment] {
        // Checks task cancellation before the encoder, before prefill and before every decoded token.
        func transcribe(context: String?) throws -> String {
            try model.transcribeCheckingCancellation(
                audio: samples,
                sampleRate: speechSampleRate,
                options: Qwen3DecodingOptions(language: languageHint, context: context)
            )
        }
        guard let context = Self.context(for: vocabulary) else {
            return [RecognizedSegment(text: try transcribe(context: nil))]
        }
        let text = try transcribe(context: context)
        guard Self.mayBeMadeUp(text, from: vocabulary) else { return [RecognizedSegment(text: text)] }
        return [RecognizedSegment(text: try transcribe(context: nil))]
    }

    /// Most vocabulary terms put into the prompt, so it stays short.
    static let maximumContextTerms = 100

    /// The prompt's context for `vocabulary`: its terms separated by commas, the first
    /// `maximumContextTerms` of them. `nil` if there are none.
    static func context(for vocabulary: [String]) -> String? {
        let terms = vocabulary.prefix(maximumContextTerms)
        return terms.isEmpty ? nil : terms.joined(separator: ", ")
    }

    /// Whether `text`, recognized with `vocabulary` as context, is empty or only words that are in
    /// the vocabulary, as when the model writes out the context instead of what it heard.
    static func mayBeMadeUp(_ text: String, from vocabulary: [String]) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        let spoken = words(text)
        guard !spoken.isEmpty else { return true }
        let known = Set(vocabulary.flatMap(words))
        return spoken.count > 1 && spoken.allSatisfy(known.contains)
    }

    func unload() {
        model.unload()
    }

    /// Qwen3-ASR's prompt takes the English language name ("language German<asr_text>", the same form it
    /// emits when auto-detecting). These are the 30 languages on the Qwen3-ASR model card; Cantonese has
    /// no ISO 639-1 code, so its 639-3 code is accepted too.
    private static let languageNames: [String: String] = [
        "ar": "Arabic", "cs": "Czech", "da": "Danish", "de": "German", "el": "Greek", "en": "English",
        "es": "Spanish", "fa": "Persian", "fi": "Finnish", "fil": "Filipino", "fr": "French", "hi": "Hindi",
        "hu": "Hungarian", "id": "Indonesian", "it": "Italian", "ja": "Japanese", "ko": "Korean",
        "mk": "Macedonian", "ms": "Malay", "nl": "Dutch", "pl": "Polish", "pt": "Portuguese", "ro": "Romanian",
        "ru": "Russian", "sv": "Swedish", "th": "Thai", "tl": "Filipino", "tr": "Turkish", "vi": "Vietnamese",
        "yue": "Cantonese", "zh": "Chinese",
    ]
}
