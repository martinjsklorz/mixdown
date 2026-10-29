@preconcurrency internal import CohereTranscribeASR
import Foundation
import MixdownCore

/// Cohere Transcribe 2B (MLX). Plain text, no timestamps, so the engine feeds it short VAD pieces.
///
/// Cohere doesn't detect the language: its prompt always names one. Without a language setting it
/// uses the Mac's language if Cohere knows it, else English, as Apple Speech does.
final class CohereRecognizer: SpeechRecognizer, @unchecked Sendable {
    private let model: CohereTranscribeModel

    /// Cohere transcribes at most 35 s (`max_audio_clip_s`) per call and cuts longer input itself,
    /// at its quietest point. Pieces of at most 20 s never reach that, and stay short enough for a
    /// call's two inputs to interleave line by line in the note.
    let chunking = SpeechChunker.Configuration(maxWindowDuration: 20, maxMergeGap: 0.8, padding: 0.25)

    private init(model: CohereTranscribeModel) {
        self.model = model
    }

    static func load(
        _ cached: CachedModel,
        cacheBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CohereRecognizer {
        let model = try await cached.load(base: cacheBase, progress: progress) { directory, offline, progress in
            try await CohereTranscribeModel.fromPretrained(
                cached.repositoryID,
                cacheDir: directory,
                offlineMode: offline,
                progressHandler: { progress($0) }
            )
        }
        return CohereRecognizer(model: model)
    }

    /// Offline, `fromPretrained` checks only for weights, so also require the config and the
    /// tokenizer files it downloads with them (`CohereTranscribeModel.downloadAdditionalFiles`).
    static let requiredFiles = ["config.json", "tokenizer.model", "tokenizer_config.json"]

    func languageHint(forISOCode code: String) -> String? {
        Self.languages.contains(code) ? code : nil
    }

    /// Cohere Transcribe takes no vocabulary.
    func recognize(_ samples: [Float], languageHint: String?, vocabulary: [String]) throws -> [RecognizedSegment] {
        // Not cancellable once started; the engine checks between pieces.
        try Task.checkCancellation()
        let text = model.transcribe(
            audio: samples,
            sampleRate: speechSampleRate,
            options: CohereTranscribeDecodingOptions(language: languageHint ?? Self.fallbackLanguage)
        )
        return [RecognizedSegment(text: text)]
    }

    /// `CohereTranscribeModel` has no `unload()`; its weights are freed with the instance.
    func unload() {}

    /// The Mac's language if Cohere knows it, else English.
    private static var fallbackLanguage: String {
        let code = Locale.current.language.languageCode?.identifier
        return code.flatMap { languages.contains($0) ? $0 : nil } ?? "en"
    }

    /// The 14 languages on the Cohere Transcribe model card, as ISO 639-1 codes. Its tokenizer
    /// turns anything else into English (`CohereTranscribeTokenizer.languageToken(for:)`).
    private static let languages: Set<String> = [
        "ar", "de", "el", "en", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt", "vi", "zh",
    ]
}
