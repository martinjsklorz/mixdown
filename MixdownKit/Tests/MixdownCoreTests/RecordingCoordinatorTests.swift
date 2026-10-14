import Foundation
@testable import MixdownCore
import Testing

@MainActor
struct RecordingCoordinatorTests {
    private func makeCoordinator(
        devices: [AudioInputDevice] = Fixtures.devices,
        updates: [[AudioInputDevice]] = [],
        capture: MockCapture = MockCapture(),
        engine: MockEngine = MockEngine(),
        writer: InMemoryNoteWriter = InMemoryNoteWriter(),
        preferredDeviceID: String? = nil
    ) -> RecordingCoordinator {
        RecordingCoordinator(
            deviceProvider: MockDeviceProvider(devices: devices, updates: updates),
            captureFactory: MockCaptureFactory(capture: capture),
            engine: engine,
            noteWriter: writer,
            preferredDeviceID: preferredDeviceID,
            now: { Fixtures.startDate }
        )
    }

    // MARK: - Device selection

    @Test func selectsDefaultMicrophone() async {
        let coordinator = makeCoordinator()
        #expect(coordinator.selectedDevice == nil)
        #expect(!coordinator.canStartRecording)

        await coordinator.monitorDevices()

        #expect(coordinator.devices == Fixtures.devices)
        #expect(coordinator.selectedDevice == Fixtures.builtInMic)
        #expect(coordinator.canStartRecording)
    }

    @Test func prefersPreferredDevice() async {
        let coordinator = makeCoordinator(preferredDeviceID: AudioInputDevice.systemAudioID)
        await coordinator.monitorDevices()
        #expect(coordinator.selectedDevice == .systemAudio)
    }

    @Test func missingPreferredDeviceFallsBackToDefault() async {
        let coordinator = makeCoordinator(preferredDeviceID: "unplugged")
        await coordinator.monitorDevices()
        #expect(coordinator.selectedDevice == Fixtures.builtInMic)
    }

    @Test func fallsBackToFirstDeviceWithoutDefault() async {
        let other = AudioInputDevice(id: "other", name: "Other", kind: .microphone)
        let coordinator = makeCoordinator(devices: [Fixtures.usbMic, other])
        await coordinator.monitorDevices()
        #expect(coordinator.selectedDevice == Fixtures.usbMic)
    }

    @Test func keepsSelectionAcrossUpdatesUntilItDisappears() async {
        let coordinator = makeCoordinator(
            updates: [[Fixtures.builtInMic, Fixtures.usbMic]],
            preferredDeviceID: Fixtures.usbMic.id
        )
        await coordinator.monitorDevices()
        #expect(coordinator.selectedDevice == Fixtures.usbMic)

        let removal = makeCoordinator(
            updates: [[Fixtures.builtInMic, Fixtures.usbMic], [Fixtures.builtInMic]],
            preferredDeviceID: Fixtures.usbMic.id
        )
        await removal.monitorDevices()
        #expect(removal.selectedDevice == Fixtures.builtInMic)
        #expect(removal.devices == [Fixtures.builtInMic])
    }

    @Test func selectDeviceIsIgnoredWhileRecording() async {
        let coordinator = makeCoordinator()
        await coordinator.monitorDevices()
        coordinator.selectDevice(Fixtures.usbMic)
        #expect(coordinator.selectedDevice == Fixtures.usbMic)

        await coordinator.startRecording()
        #expect(coordinator.isRecording)
        coordinator.selectDevice(Fixtures.builtInMic)
        #expect(coordinator.selectedDevice == Fixtures.usbMic)

        await coordinator.stopRecording()
        #expect(coordinator.phase == .idle)
    }

    // MARK: - Recording

    @Test func startAndStopWritesNote() async throws {
        let capture = MockCapture(chunks: [
            Fixtures.chunk(seconds: 1),
            Fixtures.chunk(seconds: 1, startTime: 1),
        ])
        let transcript = Transcript(
            segments: [
                TranscriptSegment(start: 0, end: 1, text: " Hello"),
                TranscriptSegment(start: 1, end: 2, text: "world "),
            ],
            language: "en"
        )
        let engine = MockEngine(transcript: transcript)
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(capture: capture, engine: engine, writer: writer)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        #expect(coordinator.phase == .recording(startedAt: Fixtures.startDate))
        #expect(coordinator.isRecording)
        #expect(!coordinator.canStartRecording)

        await coordinator.stopRecording()

        #expect(coordinator.phase == .idle)
        #expect(capture.stopCount == 1)
        let sampleCounts = await engine.receivedSampleCounts
        #expect(sampleCounts == [32_000])

        let notes = await writer.notes
        #expect(notes.count == 1)
        let note = try #require(notes.first)
        #expect(note.transcript == transcript)
        #expect(note.transcript.text == "Hello world")
        #expect(note.duration == 2)
        #expect(note.source == Fixtures.builtInMic)
        #expect(note.createdAt == Fixtures.startDate)
        #expect(note.engine == engine.info)
        #expect(note.title.hasPrefix("Recording "))
        #expect(coordinator.lastNoteURL == URL(fileURLWithPath: "/tmp/mixdown-test-1.md"))
    }

    @Test func toggleStartsAndStops() async {
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            writer: writer
        )
        await coordinator.monitorDevices()

        await coordinator.toggleRecording()
        #expect(coordinator.isRecording)
        await coordinator.toggleRecording()
        #expect(coordinator.phase == .idle)
        #expect(await writer.notes.count == 1)
    }

    @Test func tooShortRecordingIsDiscarded() async {
        let engine = MockEngine()
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 0.25)]),
            engine: engine,
            writer: writer
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        await coordinator.stopRecording()

        #expect(coordinator.phase == .idle)
        #expect(coordinator.lastNoteURL == nil)
        #expect(await engine.receivedSampleCounts.isEmpty)
        #expect(await writer.notes.isEmpty)
    }

    @Test func engineErrorFails() async {
        let error = TranscriptionError.failed("boom")
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            engine: MockEngine(transcribeError: error),
            writer: writer
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        await coordinator.stopRecording()

        #expect(coordinator.phase == .failed(message: error.localizedDescription))
        #expect(coordinator.lastNoteURL == nil)
        #expect(await writer.notes.isEmpty)
    }

    @Test func startErrorFailsAndDismissReturnsToIdle() async {
        let error = AudioCaptureError.microphonePermissionDenied
        let coordinator = makeCoordinator(capture: MockCapture(startError: error))
        await coordinator.monitorDevices()

        await coordinator.startRecording()

        #expect(coordinator.phase == .failed(message: error.localizedDescription))
        #expect(!coordinator.isRecording)
        #expect(coordinator.canStartRecording)

        coordinator.dismissError()
        #expect(coordinator.phase == .idle)
    }

    @Test func captureErrorMidRecordingSavesPartialAudio() async throws {
        let error = AudioCaptureError.deviceNotFound("USB Microphone")
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1)], streamError: error)
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(capture: capture, writer: writer)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.lastNoteURL != nil }

        let expected = RecordingCoordinator.Phase.failed(message: RecordingCoordinator.interruptedMessage(for: error))
        #expect(coordinator.phase == expected)
        #expect(capture.stopCount == 1)
        #expect(await writer.notes.first?.duration == 1)
        // Stopping after the failure is a no-op.
        await coordinator.stopRecording()
        #expect(capture.stopCount == 1)
        #expect(coordinator.phase == expected)
    }

    @Test func captureErrorBeforeAnyAudioFails() async throws {
        let error = AudioCaptureError.deviceNotFound("USB Microphone")
        let capture = MockCapture(streamError: error)
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(capture: capture, writer: writer)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { !coordinator.isRecording }

        #expect(coordinator.phase == .failed(message: error.localizedDescription))
        #expect(await writer.notes.isEmpty)
    }

    @Test func streamEndingOnItsOwnFinishesRecording() async throws {
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1)], finishesOnStart: true)
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(capture: capture, writer: writer)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.lastNoteURL != nil }

        #expect(coordinator.phase == .idle)
        #expect(await writer.notes.count == 1)
    }

    @Test func dismissErrorIgnoresOtherPhases() async {
        let coordinator = makeCoordinator()
        coordinator.dismissError()
        #expect(coordinator.phase == .idle)
    }

    // MARK: - Engine preparation

    @Test func prepareEngineReturnsToIdle() async {
        let engine = MockEngine()
        let coordinator = makeCoordinator(engine: engine)

        await coordinator.prepareEngine()

        #expect(coordinator.phase == .idle)
        #expect(await engine.prepareCount == 1)
        #expect(coordinator.engineInfo == engine.info)
    }

    @Test func prepareEngineErrorFails() async {
        let error = TranscriptionError.modelUnavailable("offline")
        let coordinator = makeCoordinator(engine: MockEngine(prepareError: error))

        await coordinator.prepareEngine()

        #expect(coordinator.phase == .failed(message: error.localizedDescription))
    }

    @Test func cancelPreparationStopsEngineAndReturnsToIdle() async throws {
        let engine = MockEngine(preparesUntilCancelled: true)
        let coordinator = makeCoordinator(engine: engine)

        let preparing = Task { await coordinator.prepareEngine() }
        try await waitUntil { coordinator.phase == .preparingModel(progress: 0.5) }
        coordinator.cancelPreparation()

        #expect(coordinator.phase == .idle)
        #expect(coordinator.preparationTimeRemaining == nil)
        await preparing.value
        #expect(coordinator.phase == .idle)
        #expect(await engine.cancelledPrepareCount == 1)
    }

    @Test func cancelledPreparationDoesNotOverrideNextOne() async throws {
        let engine = MockEngine(preparesUntilCancelled: true)
        let coordinator = makeCoordinator(engine: engine)

        let first = Task { await coordinator.prepareEngine() }
        try await waitUntil { coordinator.phase == .preparingModel(progress: 0.5) }
        coordinator.cancelPreparation()
        let second = Task { await coordinator.prepareEngine() }
        try await waitUntil { coordinator.isBusy }
        await first.value

        #expect(coordinator.isBusy)
        coordinator.cancelPreparation()
        await second.value
        #expect(coordinator.phase == .idle)
        #expect(await engine.prepareCount == 2)
        #expect(await engine.cancelledPrepareCount == 2)
    }

    @Test func cancellingCallerCancelsPreparation() async throws {
        let engine = MockEngine(preparesUntilCancelled: true)
        let coordinator = makeCoordinator(engine: engine)

        let preparing = Task { await coordinator.prepareEngine() }
        try await waitUntil { coordinator.phase == .preparingModel(progress: 0.5) }
        preparing.cancel()
        await preparing.value

        #expect(coordinator.phase == .idle)
        #expect(await engine.cancelledPrepareCount == 1)
    }

    @Test func cancelPreparationIgnoresOtherPhases() async {
        let error = TranscriptionError.modelUnavailable("offline")
        let coordinator = makeCoordinator(engine: MockEngine(prepareError: error))
        await coordinator.prepareEngine()

        coordinator.cancelPreparation()

        #expect(coordinator.phase == .failed(message: error.localizedDescription))
    }
}
