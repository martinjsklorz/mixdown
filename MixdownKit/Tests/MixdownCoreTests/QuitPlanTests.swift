import Foundation
import Testing

@testable import MixdownCore

/// What quitting does, by what Mixdown is doing and whether the Mac's session is ending.
@MainActor
struct QuitPlanTests {
    private func makeCoordinator(
        store: RecordingStore? = nil,
        capture: MockCapture = MockCapture(),
        engine: MockEngine = MockEngine(),
        writer: any NoteWriting = InMemoryNoteWriter(),
        audioFileDecoder: MockAudioFileDecoder? = nil
    ) -> RecordingCoordinator {
        RecordingCoordinator(
            deviceProvider: MockDeviceProvider(devices: Fixtures.devices),
            captureFactory: MockCaptureFactory(capture: capture),
            engine: engine,
            noteWriter: writer,
            audioFileDecoder: audioFileDecoder,
            recordingStore: store,
            now: { Fixtures.startDate }
        )
    }

    @Test func quitsAtOnceWithNothingToLose() async {
        let coordinator = makeCoordinator()
        await coordinator.monitorDevices()

        #expect(coordinator.quitPlan(isSessionEnding: false) == .quitNow)
        #expect(coordinator.quitPlan(isSessionEnding: true) == .quitNow)
    }

    @Test func recordingKeptOnDiskStopsWithoutANoteAsTheSessionEnds() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let coordinator = makeCoordinator(store: store, capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]))
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        #expect(coordinator.quitPlan(isSessionEnding: true) == .stopWithoutNoteThenQuit)
        #expect(coordinator.quitPlan(isSessionEnding: false) == .askWhileRecording(keepsRecording: true))
        await coordinator.stopRecording()
    }

    @Test func recordingOnlyInMemoryIsStoppedAndWaitedForAsTheSessionEnds() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let coordinator = makeCoordinator(store: store, capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]))
        coordinator.keepsAudioOnDisk = false
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        #expect(coordinator.quitPlan(isSessionEnding: true) == .stopThenQuitWhenDone)
        #expect(coordinator.quitPlan(isSessionEnding: false) == .askWhileRecording(keepsRecording: false))
        await coordinator.stopRecording()
    }

    @Test func importIsQuitAsTheSessionEndsButAskedAboutOtherwise() async throws {
        let gate = Gate()
        let coordinator = makeCoordinator(audioFileDecoder: MockAudioFileDecoder(gate: gate))
        await coordinator.monitorDevices()
        let importing = Task { await coordinator.importAudio(from: URL(fileURLWithPath: "/tmp/Interview.m4a")) }
        try await waitUntil { coordinator.importingFileName != nil }

        #expect(coordinator.quitPlan(isSessionEnding: true) == .quitNow)
        #expect(
            coordinator.quitPlan(isSessionEnding: false)
                == .askWhileMakingNote(importing: "Interview.m4a", keepsRecording: false)
        )
        await gate.open()
        await importing.value
    }

    @Test func asksBeforeLosingNotesAndRecordingsOnlyInMemory() async throws {
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            engine: MockEngine(transcribeError: TranscriptionError.failed("boom"))
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        await coordinator.stopRecording()
        #expect(
            coordinator.quitPlan(isSessionEnding: false) == .askAboutLosingWork(pendingNotes: 0, recordingsInMemory: 1)
        )

        let unsaved = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            writer: FlakyNoteWriter(failures: 10)
        )
        await unsaved.monitorDevices()
        await unsaved.startRecording()
        await unsaved.stopRecording()
        #expect(unsaved.quitPlan(isSessionEnding: true) == .askAboutLosingWork(pendingNotes: 1, recordingsInMemory: 0))
    }
}
