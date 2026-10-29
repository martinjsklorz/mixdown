@preconcurrency internal import AudioCommon
import Foundation
import MixdownCore
import os

let transcriptionLogger = Logger(subsystem: "app.mixdown", category: "transcription")

/// Every model here takes 16 kHz mono, which is also what `TranscriptionEngine` receives.
let speechSampleRate = Int(AudioChunk.sampleRate)

/// Text recognized in one `SpeechPiece`.
struct RecognizedSegment: Sendable {
    var text: String
    /// Seconds relative to the start of the recognizer's input, or `nil` if the model doesn't time its
    /// output (the piece's VAD bounds are used instead).
    var timing: TimeSpan?
    var speaker: String?
}

/// One speech-swift model behind `SpeechSwiftEngine`. Add a conforming type and a
/// `SpeechSwiftModel.recognizerType` case to support another model.
///
/// Conformers wrap non-thread-safe speech-swift classes. They're `@unchecked Sendable` because
/// `SpeechSwiftEngine` is their only user and runs one call at a time.
protocol SpeechRecognizer: AnyObject, Sendable {
    /// Downloads (if needed) and loads `model`'s weights below `cacheBase`.
    /// - Parameter progress: 0...1; may be called from any thread.
    static func load(
        _ model: CachedModel,
        cacheBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Self

    /// The files besides the weights that loading needs, for `CachedModel.requiredFiles`.
    static var requiredFiles: [String] { get }

    /// How the engine cuts the recording before calling `recognize`.
    var chunking: SpeechChunker.Configuration { get }

    /// The model's language hint for an ISO 639-1 code, or `nil` if it takes none for that language.
    func languageHint(forISOCode code: String) -> String?

    /// Transcribes 16 kHz mono samples. Synchronous and GPU-bound; may throw `CancellationError`.
    /// - Parameter vocabulary: Names and jargon to expect, for models that take them.
    func recognize(_ samples: [Float], languageHint: String?, vocabulary: [String]) throws -> [RecognizedSegment]

    /// Frees the weights it can right away. The instance is unusable afterwards; the rest of its
    /// memory goes with it.
    func unload()
}

extension SpeechPiece {
    /// Positions recognizer output on the recording's timeline. `nil` for empty text.
    func place(_ segment: RecognizedSegment) -> TranscriptSegment? {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let span: TimeSpan
        if let timing = segment.timing {
            let start = min(max(window.start + timing.start, window.start), window.end)
            let end = min(max(window.start + timing.end, start), window.end)
            span = TimeSpan(start: start, end: end)
        } else {
            span = speech
        }
        return TranscriptSegment(start: span.start, end: span.end, text: text, speaker: segment.speaker)
    }
}

// MARK: - Loading

/// One speech-swift model's files below the models folder: where they go, whether they look
/// complete, and loading them from there.
struct CachedModel: Sendable {
    /// Hugging Face repository with the weights.
    let repositoryID: String
    /// Files that must be there besides the weights.
    let requiredFiles: [String]
    /// Whether the weights are files `HuggingFaceDownloader.weightsExist` recognizes. Otherwise
    /// `requiredFiles` has to name them.
    var requiresWeights = true

    /// Where the files go below `base`. Created if missing, so only for loading.
    func directory(base: URL) throws -> URL {
        try ModelCache.directory(for: repositoryID, base: base)
    }

    /// Whether `directory` holds enough of the model to try an offline load.
    func looksComplete(in directory: URL) -> Bool {
        requiresWeights
            ? ModelCache.contains(weightsAnd: requiredFiles, in: directory)
            : ModelCache.contains(requiredFiles, in: directory)
    }

    /// Whether the model is on disk below `base`. Checks files only and creates nothing, so it's
    /// cheap enough for the main actor.
    func isDownloaded(base: URL) -> Bool {
        guard let directory = ModelCache.existingDirectory(for: repositoryID, base: base) else { return false }
        return looksComplete(in: directory)
    }

    /// Loads the model from below `base` with `ModelDirectory.loadPreferringCache`, which
    /// downloads what's missing.
    /// - Parameter fromPretrained: speech-swift's loader, given the directory, whether to stay
    ///   offline, and the progress to report.
    func load<Model>(
        base: URL,
        progress: @escaping @Sendable (Double) -> Void,
        _ fromPretrained: (
            _ directory: URL, _ offline: Bool, _ progress: @escaping @Sendable (Double) -> Void
        ) async throws -> Model
    ) async throws -> Model {
        let directory = try directory(base: base)
        return try await ModelDirectory.loadPreferringCache(
            repositoryID,
            cacheLooksComplete: looksComplete(in: directory),
            progress: progress
        ) { offline, progress in
            try await fromPretrained(directory, offline, progress)
        }
    }
}

enum ModelCache {
    /// Per-repository directory below `base` (speech-swift's `models/<org>/<name>` layout). Created if missing.
    static func directory(for repositoryID: String, base: URL) throws -> URL {
        try HuggingFaceDownloader.getCacheDirectory(for: repositoryID, basePath: base)
    }

    /// The directory `directory(for:base:)` returns, without creating it: the older flat layout's
    /// if that holds weights, else `models/<org>/<name>`. `nil` if it doesn't exist.
    static func existingDirectory(for repositoryID: String, base: URL) -> URL? {
        let legacy = base.appendingPathComponent(
            HuggingFaceDownloader.sanitizedCacheKey(for: repositoryID),
            isDirectory: true
        )
        let directory =
            HuggingFaceDownloader.weightsExist(in: legacy)
            ? legacy : base.appending(component: "models").appending(component: repositoryID)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return directory
    }

    /// Whether `directory` holds weights (all shards, if indexed) and every one of `files`.
    /// Weights alone are all speech-swift's offline mode checks for.
    static func contains(weightsAnd files: [String], in directory: URL) -> Bool {
        HuggingFaceDownloader.weightsExist(in: directory) && contains(files, in: directory)
    }

    /// Whether `directory` holds every one of `files`, for models whose weights aren't in the
    /// files `contains(weightsAnd:in:)` looks for.
    static func contains(_ files: [String], in directory: URL) -> Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }
}
