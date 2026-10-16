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
    /// Downloads (if needed) and loads the weights for `repositoryID` below `cacheBase`.
    /// - Parameter progress: 0...1; may be called from any thread.
    static func load(
        repositoryID: String,
        cacheBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Self

    /// Whether `directory` (from `ModelCache.directory`) holds enough of the model to try an offline load.
    static func cacheLooksComplete(in directory: URL) -> Bool

    /// How the engine cuts the recording before calling `recognize`.
    var chunking: SpeechChunker.Configuration { get }

    /// The model's language hint for an ISO 639-1 code, or `nil` if it takes none for that language.
    func languageHint(forISOCode code: String) -> String?

    /// Transcribes 16 kHz mono samples. Synchronous and GPU-bound; may throw `CancellationError`.
    func recognize(_ samples: [Float], languageHint: String?) throws -> [RecognizedSegment]

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

enum ModelCache {
    /// Per-repository directory below `base` (speech-swift's `models/<org>/<name>` layout). Created if missing.
    static func directory(for repositoryID: String, base: URL) throws -> URL {
        try HuggingFaceDownloader.getCacheDirectory(for: repositoryID, basePath: base)
    }

    /// Whether `directory` holds weights (all shards, if indexed) and every one of `files`.
    /// Weights alone are all speech-swift's offline mode checks for.
    static func contains(weightsAnd files: [String], in directory: URL) -> Bool {
        HuggingFaceDownloader.weightsExist(in: directory)
            && files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// Loads from disk without touching the network first, then falls back to an online load.
    ///
    /// speech-swift's online path always asks the Hub for the file list, so starting offline keeps
    /// launches fast and makes cached models work without a connection. Progress is only forwarded
    /// for the online attempt, so a failed offline attempt doesn't leave the bar stuck partway.
    static func loadPreferringCache<Model>(
        _ repositoryID: String,
        cacheLooksComplete: Bool,
        progress: @escaping @Sendable (Double) -> Void,
        load: (_ offline: Bool, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Model
    ) async throws -> Model {
        if cacheLooksComplete {
            do {
                let model = try await load(true) { _ in }
                progress(1)
                transcriptionLogger.info("Loaded \(repositoryID, privacy: .public) from cache")
                return model
            } catch let error as CancellationError {
                throw error
            } catch {
                transcriptionLogger.notice(
                    "Cached \(repositoryID, privacy: .public) unusable, downloading: \(String(describing: error), privacy: .public)"
                )
            }
        }
        transcriptionLogger.info("Downloading \(repositoryID, privacy: .public)")
        let model = try await load(false, progress)
        progress(1)
        return model
    }
}
