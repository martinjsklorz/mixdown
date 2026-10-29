import Foundation
import Testing

@testable import MixdownCore

/// What `mixdown://` links and the recording shortcut do, by what Mixdown is doing.
@MainActor
struct URLCommandActionTests {
    private func makeCoordinator(
        engine: MockEngine = MockEngine(),
        writer: (any NoteWriting)? = InMemoryNoteWriter()
    ) async -> RecordingCoordinator {
        let coordinator = RecordingCoordinator(
            deviceProvider: MockDeviceProvider(devices: Fixtures.devices),
            captureFactory: MockCaptureFactory(capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)])),
            engine: engine,
            noteWriter: writer,
            now: { Fixtures.startDate }
        )
        await coordinator.monitorDevices()
        return coordinator
    }

    @Test func whileIdle() async {
        let coordinator = await makeCoordinator()
        #expect(coordinator.action(for: .toggleRecording) == .startRecording)
        #expect(coordinator.action(for: .startRecording) == .startRecording)
        #expect(coordinator.action(for: .stopRecording) == .nothing)
        #expect(coordinator.action(for: .pauseRecording) == .beep)
        #expect(coordinator.action(for: .resumeRecording) == .beep)
        #expect(coordinator.action(for: .togglePause) == .beep)
        #expect(coordinator.action(for: .markMoment(text: "Budget")) == .beep)
        #expect(coordinator.action(for: .markMoment(text: nil)) == .markMoment)
        #expect(coordinator.action(for: .open(note: nil)) == .showMainWindow)
        #expect(coordinator.action(for: .open(note: "latest")) == .openNote("latest"))
    }

    @Test func whileRecording() async {
        let coordinator = await makeCoordinator()
        await coordinator.startRecording()
        #expect(coordinator.action(for: .toggleRecording) == .stopRecording)
        #expect(coordinator.action(for: .startRecording) == .nothing)
        #expect(coordinator.action(for: .stopRecording) == .stopRecording)
        #expect(coordinator.action(for: .pauseRecording) == .pauseRecording)
        #expect(coordinator.action(for: .resumeRecording) == .resumeRecording)
        #expect(coordinator.action(for: .togglePause) == .togglePause)
        guard case .addMoment(_, "Budget") = coordinator.action(for: .markMoment(text: "Budget")) else {
            Issue.record("Expected the moment to be added")
            return
        }
        await coordinator.stopRecording()
    }

    @Test func whilePaused() async {
        let coordinator = await makeCoordinator()
        await coordinator.startRecording()
        await coordinator.pauseRecording()
        #expect(coordinator.action(for: .toggleRecording) == .stopRecording)
        #expect(coordinator.action(for: .resumeRecording) == .resumeRecording)
        #expect(coordinator.action(for: .togglePause) == .togglePause)
        await coordinator.stopRecording()
    }

    @Test func whenTheUserHasToDoSomethingFirstRecordSaysWhat() async {
        // No notes folder to save to.
        let coordinator = await makeCoordinator(writer: nil)
        #expect(coordinator.action(for: .toggleRecording) == .showRecorder)
        #expect(coordinator.action(for: .startRecording) == .showRecorder)
    }

    @Test func whileBusyItBeeps() async throws {
        let coordinator = await makeCoordinator(engine: MockEngine(isDownloaded: false, preparesUntilCancelled: true))
        let preparing = Task { await coordinator.prepareEngine() }
        try await waitUntil { !coordinator.isIdle }
        #expect(coordinator.action(for: .toggleRecording) == .beep)
        #expect(coordinator.action(for: .startRecording) == .beep)
        preparing.cancel()
        await preparing.value
    }
}
