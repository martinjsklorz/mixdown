import Foundation
import Synchronization

@testable import MixdownSpeechSwift

/// Answers each `recognize` call with the next of `results`, recording the inputs.
final class FakeRecognizer: SpeechRecognizer, @unchecked Sendable {
    static let requiredFiles: [String] = []

    let chunking = SpeechChunker.Configuration(maxWindowDuration: 30, maxMergeGap: 1, padding: 0)
    private var results: [Result<[RecognizedSegment], any Error>]
    private(set) var inputs: [[Float]] = []
    /// Runs before each call returns, e.g. to cancel the task.
    var onRecognize: () -> Void = {}

    init(_ results: [Result<[RecognizedSegment], any Error>]) {
        self.results = results
    }

    static func load(
        _ model: CachedModel,
        cacheBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Self {
        fatalError("Not loaded in tests")
    }

    func languageHint(forISOCode code: String) -> String? { code }

    func recognize(_ samples: [Float], languageHint: String?, vocabulary: [String]) throws -> [RecognizedSegment] {
        inputs.append(samples)
        onRecognize()
        return try results.isEmpty ? [] : results.removeFirst().get()
    }

    func unload() {}
}

/// Collects the values a `MonotonicProgress` forwards.
final class ProgressLog: Sendable {
    private let values = Mutex<[Double]>([])

    var reported: [Double] { values.withLock { $0 } }

    func record(_ value: Double) {
        values.withLock { $0.append(value) }
    }
}
