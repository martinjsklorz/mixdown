@preconcurrency internal import AudioCommon
import Foundation
internal import MLXLMCommon
import MixdownCore
internal import Tokenizers

/// Where a model's files live and how they get there: speech-swift's Hugging Face downloader, into
/// the folder the speech models use, so Mixdown keeps all its models in one place.
enum ModelFiles {
    /// Files the loader reads besides the weights: configuration, tokenizer and chat template.
    private static let supportFiles = ["*.json", "*.jinja"]

    /// `Application Support/Mixdown/Models`, inside the container when sandboxed. Shared with the
    /// speech models.
    static func baseDirectory() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            throw SummarizationError.unavailable("Application Support directory not found")
        }
        return support.appendingPathComponent("Mixdown/Models", isDirectory: true)
    }

    /// The model's directory below `baseDirectory()`. Created if missing.
    static func directory(for model: MLXLanguageModel) throws -> URL {
        try HuggingFaceDownloader.getCacheDirectory(for: model.repositoryID, basePath: baseDirectory())
    }

    /// Where `directory(for:)` puts the model (the Hub's `models/<org>/<name>` layout), without
    /// creating it, so checking every model for Settings leaves no empty folders behind.
    private static func existingDirectory(for model: MLXLanguageModel) -> URL? {
        guard let base = try? baseDirectory() else { return nil }
        let directory = base.appendingPathComponent("models/\(model.repositoryID)", isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    /// Whether the model is on disk with everything the loader needs. Checks files only; it
    /// doesn't validate them.
    static func isComplete(_ model: MLXLanguageModel) -> Bool {
        existingDirectory(for: model).map(isComplete) ?? false
    }

    private static func isComplete(_ directory: URL) -> Bool {
        HuggingFaceDownloader.weightsExist(in: directory)
            && ["config.json", "tokenizer.json", "tokenizer_config.json"].allSatisfy {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
    }

    /// Downloads what's missing of the model, unless it's all on disk already: that skips the
    /// Hub, so loading a downloaded model is quick and works offline. Files already on disk are
    /// kept when cancelled, so the next call resumes from them.
    static func download(
        _ model: MLXLanguageModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let directory = try directory(for: model)
        if isComplete(directory) {
            progress(1)
            return directory
        }
        try await HuggingFaceDownloader.downloadWeights(
            modelId: model.repositoryID,
            to: directory,
            additionalFiles: supportFiles,
            progressHandler: { progress($0) }
        )
        progress(1)
        return directory
    }

    static func delete(_ model: MLXLanguageModel) throws {
        guard let directory = existingDirectory(for: model) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}

/// Loads a tokenizer with swift-transformers, as mlx-swift-lm's `#huggingFaceTokenizerLoader()`
/// macro does, without needing macros enabled to build.
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

/// A swift-transformers tokenizer as mlx-swift-lm's `Tokenizer`.
private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
