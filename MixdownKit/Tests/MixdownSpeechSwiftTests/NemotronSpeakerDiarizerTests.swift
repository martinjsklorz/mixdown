import MixdownCore
import Synchronization
import Testing

@testable import MixdownSpeechSwift

struct NemotronSpeakerDiarizerTests {
    @Test func concurrentCallersShareOneDownload() async throws {
        let store = FakeDiarizerStore()
        let diarizer = store.makeDiarizer()

        async let prepared: Void = diarizer.prepare(progress: nil)
        async let first = diarizer.diarize([0, 0])
        async let second = diarizer.diarize([0, 0, 0])
        // Long enough for every caller to reach the download before it finishes.
        try await Task.sleep(for: .milliseconds(100))
        store.finishDownload()

        try await prepared
        #expect(try await first == [SpeakerTurn(start: 0, end: 2, speaker: 0)])
        #expect(try await second == [SpeakerTurn(start: 0, end: 3, speaker: 0)])
        #expect(store.downloads == 1)
        // The download's instance serves one diarization; the other loads its own from disk.
        #expect(store.loads <= 3)
    }

    @Test func diarizeUsesTheModelItDownloaded() async throws {
        let store = FakeDiarizerStore()
        let diarizer = store.makeDiarizer()
        store.finishDownload()

        _ = try await diarizer.diarize([0])

        #expect(store.downloads == 1)
        #expect(store.loads == 1)
    }

    @Test func prepareDoesNothingOnceDownloaded() async throws {
        let store = FakeDiarizerStore(isOnDisk: true)

        try await store.makeDiarizer().prepare(progress: nil)

        #expect(store.loads == 0)
    }

    @Test func aCancelledDownloadIsRestartedForWhoeverStillNeedsIt() async throws {
        let store = FakeDiarizerStore()
        let diarizer = store.makeDiarizer()

        let preparing = Task { try await diarizer.prepare(progress: nil) }
        while store.downloads == 0 { await Task.yield() }
        async let turns = diarizer.diarize([0])
        try await Task.sleep(for: .milliseconds(50))
        preparing.cancel()
        try await Task.sleep(for: .milliseconds(50))
        store.finishDownload()

        #expect(try await turns.count == 1)
        await #expect(throws: CancellationError.self) { try await preparing.value }
        #expect(store.downloads == 2)
    }
}

/// Stands in for the model's files: a download blocks until `finishDownload()`, then the model
/// is on disk.
private final class FakeDiarizerStore: Sendable {
    private struct State {
        var isOnDisk: Bool
        var downloadFinished = false
        var downloads = 0
        var loads = 0
    }

    private let state: Mutex<State>

    init(isOnDisk: Bool = false) {
        state = Mutex(State(isOnDisk: isOnDisk))
    }

    var downloads: Int { state.withLock { $0.downloads } }
    var loads: Int { state.withLock { $0.loads } }

    func finishDownload() {
        state.withLock { $0.downloadFinished = true }
    }

    func makeDiarizer() -> NemotronSpeakerDiarizer {
        NemotronSpeakerDiarizer(
            isOnDisk: { self.state.withLock { $0.isOnDisk } },
            load: { _ in try await self.load() },
            clearCache: {}
        )
    }

    private func load() async throws -> any SpeakerDiarizationModel {
        if !state.withLock({ $0.isOnDisk }) {
            state.withLock { $0.downloads += 1 }
            while !state.withLock({ $0.downloadFinished }) {
                try await Task.sleep(for: .milliseconds(5))
            }
            state.withLock { $0.isOnDisk = true }
        }
        state.withLock { $0.loads += 1 }
        return FakeDiarizationModel()
    }
}

/// One speaker throughout.
private final class FakeDiarizationModel: SpeakerDiarizationModel {
    func diarize(_ samples: [Float]) throws -> [SpeakerTurn] {
        [SpeakerTurn(start: 0, end: Double(samples.count), speaker: 0)]
    }
}
