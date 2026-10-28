import Foundation
import Testing

@testable import MixdownCore

/// Holds each write until `gate` opens, then writes like `InMemoryNoteWriter`, or fails with
/// `FlakyNoteWriter.WriteError` if `fails`.
actor GatedNoteWriter: NoteWriting {
    let gate = Gate()
    private let fails: Bool
    private(set) var startedWrites = 0
    private(set) var notes: [Note] = []

    init(fails: Bool = false) {
        self.fails = fails
    }

    func write(_ note: Note) async throws -> URL {
        startedWrites += 1
        await gate.wait()
        if fails { throw FlakyNoteWriter.WriteError() }
        notes.append(note)
        return URL(fileURLWithPath: "/tmp/mixdown-gated-\(notes.count).md")
    }
}

@MainActor
struct NoteSaverTests {
    private func note(_ title: String) -> Note {
        Note(
            title: title,
            createdAt: Fixtures.startDate,
            duration: 1,
            sources: [Fixtures.builtInMic],
            engine: TranscriptionEngineInfo(id: "mock", displayName: "Mock Engine"),
            transcript: Transcript(segments: [])
        )
    }

    /// Waits until `writer` has started `count` writes.
    private func waitForWrites(_ count: Int, of writer: GatedNoteWriter) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await writer.startedWrites < count {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for \(count) writes")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func aNoteSavedDuringAnotherSaveIsSavedAfterIt() async throws {
        let writer = GatedNoteWriter()
        let saver = NoteSaver(noteWriter: writer)
        let first = Task { await saver.save(note("A")) }
        try await waitForWrites(1, of: writer)
        #expect(saver.isSaving)

        let second = Task { await saver.save(note("B")) }
        try await waitUntil { saver.pendingNotes.count == 2 }
        await writer.gate.open()

        #expect(await first.value == nil)
        #expect(await second.value == nil)
        #expect(await writer.notes.map(\.title) == ["A", "B"])
        #expect(saver.pendingNotes.isEmpty)
        #expect(!saver.isSaving)
    }

    @Test func aNoteKeptBehindOneThatFailedGetsItsError() async throws {
        let writer = GatedNoteWriter(fails: true)
        let saver = NoteSaver(noteWriter: writer)
        saver.retryInterval = .seconds(60)
        let first = Task { await saver.save(note("A")) }
        try await waitForWrites(1, of: writer)

        let second = Task { await saver.save(note("B")) }
        try await waitUntil { saver.pendingNotes.count == 2 }
        await writer.gate.open()

        #expect(await first.value is FlakyNoteWriter.WriteError)
        #expect(await second.value is FlakyNoteWriter.WriteError)
        #expect(saver.pendingNotes.map(\.title) == ["A", "B"])
    }

    @Test func aWriteThatFailsAfterTheFolderChangedIsTriedInTheNewOne() async throws {
        let failing = GatedNoteWriter(fails: true)
        let saver = NoteSaver(noteWriter: failing)
        let saving = Task { await saver.save(note("A")) }
        try await waitForWrites(1, of: failing)

        let writer = InMemoryNoteWriter()
        saver.noteWriter = writer
        await failing.gate.open()

        #expect(await saving.value == nil)
        #expect(await writer.notes.map(\.title) == ["A"])
        #expect(saver.lastNoteURL != nil)
    }

    @Test func withoutAFolderTheNoteIsKept() async {
        let saver = NoteSaver(noteWriter: nil)

        let error = await saver.save(note("A"))

        #expect(error is NoteWritingError)
        #expect(saver.pendingNotes.map(\.title) == ["A"])
        #expect(!saver.isSaving)
    }

    @Test func pendingNotesTakenWhileWaitingToRetryArentWritten() async throws {
        let writer = FlakyNoteWriter(failures: 1)
        let saver = NoteSaver(noteWriter: writer)
        saver.retryInterval = .milliseconds(20)

        #expect(await saver.save(note("A")) is FlakyNoteWriter.WriteError)
        #expect(saver.takePendingNotes().map(\.title) == ["A"])
        #expect(saver.pendingNotes.isEmpty)

        try await Task.sleep(for: .milliseconds(100))
        #expect(await writer.notes.isEmpty)
    }

    @Test func pendingNotesArentTakenWhileTheyreBeingWritten() async throws {
        let writer = GatedNoteWriter()
        let saver = NoteSaver(noteWriter: writer)
        let saving = Task { await saver.save(note("A")) }
        try await waitForWrites(1, of: writer)

        #expect(saver.takePendingNotes().isEmpty)
        await writer.gate.open()

        #expect(await saving.value == nil)
        #expect(await writer.notes.map(\.title) == ["A"])
    }
}
