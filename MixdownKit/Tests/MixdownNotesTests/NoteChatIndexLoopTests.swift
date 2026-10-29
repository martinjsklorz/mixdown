import Foundation
import MixdownCore
import Synchronization
import Testing

@testable import MixdownNotes

/// `NoteChatIndex.index(_:embedder:didIndex:)`, the loop the app's index store runs.
struct NoteChatIndexLoopTests {
    /// Records the texts it embeds, and fails or cancels its task once it has embedded a given
    /// number of notes.
    private final class RecordingEmbedder: TextEmbedder, Sendable {
        struct Failure: Error {}

        let events = Mutex<[String]>([])
        let failsAt: Int?
        let cancelsAt: Int?

        init(failsAt: Int? = nil, cancelsAt: Int? = nil) {
            self.failsAt = failsAt
            self.cancelsAt = cancelsAt
        }

        func embed(_ texts: [String]) async throws -> [TextEmbedding?] {
            let count = events.withLock { events in
                events.append("embed")
                return events.count { $0 == "embed" }
            }
            if count == failsAt { throw Failure() }
            if count == cancelsAt { withUnsafeCurrentTask { $0?.cancel() } }
            // Gives a store's other work the chance to run, as a real model would.
            await Task.yield()
            return texts.map { _ in TextEmbedding(model: "test", vector: [1]) }
        }

        func embed(_ text: String, model: String) async throws -> TextEmbedding? { nil }
    }

    private func note(_ number: Int) -> NoteDocument {
        NoteDocument(
            url: URL(filePath: "/n/\(number).md"),
            contents: "# Note \(number)\n\nSomething said in note \(number).",
            fileDate: .distantPast
        )
    }

    @Test func handsOverEachNoteBeforeEmbeddingTheNext() async throws {
        let embedder = RecordingEmbedder()
        let notes = (1...3).map(note)

        try await NoteChatIndex.index(notes, embedder: embedder) { indexed, done in
            embedder.events.withLock { $0.append("done \(done): \(indexed.id)") }
        }

        #expect(
            embedder.events.withLock { $0 } == [
                "embed", "done 1: \(notes[0].url.absoluteString)",
                "embed", "done 2: \(notes[1].url.absoluteString)",
                "embed", "done 3: \(notes[2].url.absoluteString)",
            ]
        )
    }

    @Test func stopsEmbeddingOnceTheEmbedderFails() async throws {
        let embedder = RecordingEmbedder(failsAt: 2)
        var indexed: [NoteChatIndex.IndexedNote] = []

        try await NoteChatIndex.index((1...3).map(note), embedder: embedder) { note, _ in indexed.append(note) }

        #expect(indexed.map(\.embedderFailed) == [false, true, false])
        #expect(indexed.map(\.entry.isEmbedded) == [true, false, false])
        #expect(embedder.events.withLock { $0.count } == 2)
    }

    @Test func cancellingKeepsTheNotesDoneSoFar() async throws {
        let embedder = RecordingEmbedder(cancelsAt: 2)
        let task = Task {
            var done: [Int] = []
            do {
                try await NoteChatIndex.index((1...3).map(note), embedder: embedder) { _, count in done.append(count) }
            } catch {
                return (done, error is CancellationError)
            }
            return (done, false)
        }

        let (done, wasCancelled) = await task.value

        // The note being embedded when cancelled is still done; the next isn't started.
        #expect(wasCancelled)
        #expect(done == [1, 2])
        #expect(embedder.events.withLock { $0.count } == 2)
    }

    @Test func runsOnTheCallersActor() async throws {
        let store = Store()
        await store.update(with: (1...3).map(note))
        #expect(await store.indexed == 3)
    }

    /// Keeps what's indexed on an actor, like the app's store does.
    private actor Store {
        var indexed = 0

        func update(with notes: [NoteDocument]) async {
            try? await NoteChatIndex.index(notes, embedder: RecordingEmbedder()) { _, _ in
                self.assertIsolated()
                indexed += 1
            }
        }
    }
}
