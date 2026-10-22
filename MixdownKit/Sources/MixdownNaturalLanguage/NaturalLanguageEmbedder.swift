import Foundation
import MixdownCore
import NaturalLanguage
import os

private let logger = Logger(subsystem: "app.mixdown", category: "chat")

/// Embeds text with Apple's on-device contextual embedding models, through the NaturalLanguage
/// framework. There's one model per script, each covering many languages: the Latin one has
/// English, German, French, Spanish and more, so a question in German finds an English line. A
/// text's embedding is the average of its tokens'.
///
/// macOS downloads a model the first time it's needed and shares it with other apps. Nothing
/// leaves the Mac.
public actor NaturalLanguageEmbedder: TextEmbedder {
    /// Loaded models, by `modelIdentifier`.
    private var models: [String: NLContextualEmbedding] = [:]
    /// The model for each language asked for so far; `nil` for languages without one.
    private var modelIDs: [NLLanguage: String?] = [:]

    /// Below this, a text's own language is taken for its batch's: short lines like "Okay." are
    /// too short to tell.
    private static let minimumConfidence = 0.8

    public init() {}

    public func embed(_ texts: [String]) async throws -> [TextEmbedding?] {
        let batchLanguage = Self.language(of: texts.joined(separator: "\n"), minimumConfidence: 0)
        var embeddings: [TextEmbedding?] = []
        for text in texts {
            try Task.checkCancellation()
            guard let language = Self.language(of: text) ?? batchLanguage,
                let model = try await model(for: language)
            else {
                embeddings.append(nil)
                continue
            }
            embeddings.append(try Self.embedding(of: text, language: language, model: model))
        }
        return embeddings
    }

    public func embed(_ text: String, model id: String) async throws -> TextEmbedding? {
        guard let model = try loadedModel(id) else { return nil }
        return try Self.embedding(of: text, language: Self.language(of: text, minimumConfidence: 0), model: model)
    }

    // MARK: Models

    /// The model for `language`, downloaded and loaded. `nil` if no model covers it; throws if
    /// it can't be downloaded or loaded.
    private func model(for language: NLLanguage) async throws -> NLContextualEmbedding? {
        if let id = modelIDs[language] { return try id.flatMap(loadedModel) }
        guard let model = NLContextualEmbedding(language: language) else {
            modelIDs[language] = .some(nil)
            return nil
        }
        let id = model.modelIdentifier
        if models[id] == nil {
            if !model.hasAvailableAssets {
                logger.info("Downloading the embedding model for \(language.rawValue, privacy: .public)")
                try await Self.downloadAssets(of: model)
            }
            try model.load()
            models[id] = model
        }
        modelIDs[language] = id
        return models[id]
    }

    private func loadedModel(_ id: String) throws -> NLContextualEmbedding? {
        if let model = models[id] { return model }
        guard let model = NLContextualEmbedding(modelIdentifier: id), model.hasAvailableAssets else { return nil }
        try model.load()
        models[id] = model
        return model
    }

    private static func downloadAssets(of model: NLContextualEmbedding) async throws {
        let result = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NLContextualEmbedding.AssetsResult, any Error>) in
            model.requestAssets { result, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: result) }
            }
        }
        guard result == .available else { throw EmbedderError.assetsUnavailable }
    }

    // MARK: Embedding

    private static func embedding(
        of text: String,
        language: NLLanguage?,
        model: NLContextualEmbedding
    ) throws -> TextEmbedding? {
        let result = try model.embeddingResult(for: text, language: language)
        var sum = [Float](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for index in sum.indices where index < vector.count { sum[index] += Float(vector[index]) }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        return TextEmbedding(model: model.modelIdentifier, vector: sum.map { $0 / Float(count) })
    }

    /// The language `text` is in, if it's at least `minimumConfidence` sure.
    private static func language(of text: String, minimumConfidence: Double = minimumConfidence) -> NLLanguage? {
        TranscriptLanguage.language(of: text, minimumConfidence: minimumConfidence)
    }
}

enum EmbedderError: LocalizedError {
    case assetsUnavailable

    var errorDescription: String? {
        switch self {
        case .assetsUnavailable: "The embedding model couldn't be downloaded."
        }
    }
}
