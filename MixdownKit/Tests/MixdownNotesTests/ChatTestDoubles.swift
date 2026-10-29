import Foundation
import MixdownCore
import Synchronization
import Testing

/// Answers every question with `reply`, or keeps the answers open until `finishAnswers(with:)`,
/// and records what it was asked.
final class FakeAnswerer: NoteAnswerer {
    struct Call: Sendable {
        var question: String
        var excerpts: [NoteExcerpt]
        var history: [ChatTurn]
    }

    private struct State {
        var availability = SummarizerAvailability.available
        var calls: [Call] = []
        var open: [AsyncThrowingStream<String, any Error>.Continuation] = []
        var endedCount = 0
    }

    let excerptTokenBudget: Int
    /// `nil` to keep answers open.
    private let reply: String?
    private let state = Mutex(State())

    init(excerptTokenBudget: Int = 10_000, reply: String? = "An answer [1].") {
        self.excerptTokenBudget = excerptTokenBudget
        self.reply = reply
    }

    var availability: SummarizerAvailability {
        get { state.withLock { $0.availability } }
        set { state.withLock { $0.availability = newValue } }
    }

    var calls: [Call] { state.withLock { $0.calls } }
    /// How many answers ended, finished or stopped.
    var endedCount: Int { state.withLock { $0.endedCount } }

    func answer(
        _ question: String,
        excerpts: [NoteExcerpt],
        history: [ChatTurn],
        now: Date
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in self.state.withLock { $0.endedCount += 1 } }
            state.withLock { $0.calls.append(Call(question: question, excerpts: excerpts, history: history)) }
            if let reply {
                continuation.yield(reply)
                continuation.finish()
            } else {
                state.withLock { $0.open.append(continuation) }
            }
        }
    }

    /// Ends the answers still open with `text`.
    func finishAnswers(with text: String) {
        let open = state.withLock { state in
            defer { state.open = [] }
            return state.open
        }
        for continuation in open {
            continuation.yield(text)
            continuation.finish()
        }
    }
}

/// Embeds no passages, so Chat searches by words alone, or with `embedsPassages` the same vector
/// for every passage. Questions are embedded only once `gate` is open, if there is one.
struct GatedEmbedder: TextEmbedder {
    var embedsPassages = false
    var gate: Gate?

    func embed(_ texts: [String]) async throws -> [TextEmbedding?] {
        texts.map { _ in embedsPassages ? TextEmbedding(model: "m", vector: [1]) : nil }
    }

    func embed(_ text: String, model: String) async throws -> TextEmbedding? {
        await gate?.wait()
        return TextEmbedding(model: model, vector: [1])
    }
}

/// Holds whoever waits for it until it's opened.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var waitingCount: Int { state.withLock { $0.waiting.count } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                if !state.isOpen { state.waiting.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// How much longer than locally tests wait for what they expect, from the environment variable
/// `MIXDOWN_TEST_TIMEOUT_SCALE`, which CI sets for its slower, shared machines. 1 if unset.
let testTimeoutScale = ProcessInfo.processInfo.environment["MIXDOWN_TEST_TIMEOUT_SCALE"].flatMap(Double.init) ?? 1

/// Polls `condition` on the main actor, recording an issue if it isn't met within `timeout`
/// (times `testTimeoutScale`).
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout * testTimeoutScale
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
