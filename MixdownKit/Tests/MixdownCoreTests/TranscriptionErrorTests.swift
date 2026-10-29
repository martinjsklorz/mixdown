import Foundation
import Testing

@testable import MixdownCore

struct TranscriptionErrorTests {
    private struct ModelError: LocalizedError {
        var errorDescription: String? { "out of memory" }
    }

    private func reason(_ error: any Error) -> String? {
        switch error as? TranscriptionError {
        case .failed(let reason): "failed: \(reason)"
        case .modelUnavailable(let reason): "unavailable: \(reason)"
        case nil: nil
        }
    }

    @Test func failureWrapsOtherErrors() {
        #expect(reason(TranscriptionError.failure(ModelError())) == "failed: out of memory")
    }

    @Test func failureKeepsTranscriptionErrorsAndCancellation() {
        #expect(reason(TranscriptionError.failure(TranscriptionError.failed("no audio"))) == "failed: no audio")
        #expect(
            reason(TranscriptionError.failure(TranscriptionError.modelUnavailable("gone"))) == "unavailable: gone"
        )
        #expect(TranscriptionError.failure(CancellationError()) is CancellationError)
    }

    @Test func unavailableOrCancelledWrapsOtherErrors() {
        #expect(reason(TranscriptionError.unavailableOrCancelled(ModelError())) == "unavailable: out of memory")
        #expect(TranscriptionError.unavailableOrCancelled(CancellationError()) is CancellationError)
    }

    @Test func aCancelledTaskTurnsAnyErrorIntoCancellation() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return (
                TranscriptionError.failure(ModelError()) is CancellationError,
                TranscriptionError.unavailableOrCancelled(ModelError()) is CancellationError
            )
        }

        let (failure, unavailable) = await task.value
        #expect(failure)
        #expect(unavailable)
    }
}
