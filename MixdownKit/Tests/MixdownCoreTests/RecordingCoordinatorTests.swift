import Foundation
@testable import MixdownCore
import Testing

@MainActor
struct RecordingCoordinatorTests {
    private func makeCoordinator(
        devices: [AudioInputDevice] = Fixtures.devices,
        updates: [[AudioInputDevice]] = [],
        capture: MockCapture = MockCapture(),
        captures: [String: MockCapture] = [:],
        engine: MockEngine = MockEngine(),
        writer: InMemoryNoteWriter = InMemoryNoteWriter(),
        preferredDeviceIDs: [String] = []
    ) -> RecordingCoordinator {
        RecordingCoordinator(
            deviceProvider: MockDeviceProvider(devices: devices, updates: updates),
            captureFactory: MockCaptureFactory(capture: capture, captures: captures),
            engine: engine,
            noteWriter: writer,
            preferredDeviceIDs: preferredDeviceIDs,
            now: { Fixtures.startDate }
        )
    }

    // MARK: - Device selection

    @Test func selectsDefaultMicrophone() async {
        let coordinator = makeCoordinator()
        #expect(coordinator.selectedDevices.isEmpty)
        #expect(!coordinator.canStartRecording)

        await coordinator.monitorDevices()

        #expect(coordinator.devices == Fixtures.devices)
        #expect(coordinator.selectedDevices == [Fixtures.builtInMic])
        #expect(coordinator.canStartRecording)
    }

    @Test func prefersPreferredDevices() async {
        let coordinator = makeCoordinator(preferredDeviceIDs: [AudioInputDevice.systemAudioID])
        await coordinator.monitorDevices()
        #expect(coordinator.selectedDevices == [.systemAudio])

        let both = makeCoordinator(preferredDeviceIDs: [AudioInputDevice.systemAudioID, Fixtures.usbMic.id])
        await both.monitorDevices()
        // In device-list order, not preference order.
        #expect(both.selectedDevices == [Fixtures.usbMic, .systemAudio])
    }

    @Test func missingPreferredMicrophoneFallsBackToDefault() async {
        let coordinator = makeCoordinator(preferredDeviceIDs: ["unplugged"])
        await coordinator.monitorDevices()
        #expect(coordinator.selectedDevices == [Fixtures.builtInMic])

        let withSystemAudio = makeCoordinator(preferredDeviceIDs: ["unplugged", AudioInputDevice.systemAudioID])
        await withSystemAudio.monitorDevices()
        #expect(withSystemAudio.selectedDevices == [Fixtures.builtInMic, .systemAudio])
    }

    @Test func missingSystemAudioIsDropped() async {
        let coordinator = makeCoordinator(
            devices: [Fixtures.usbMic, Fixtures.builtInMic],
            preferredDeviceIDs: [Fixtures.usbMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()
        #expect(coordinator.selectedDevices == [Fixtures.usbMic])
    }

    @Test func fallsBackToFirstDeviceWithoutDefault() async {
        let other = AudioInputDevice(id: "other", name: "Other", kind: .microphone)
        let coordinator = makeCoordinator(devices: [Fixtures.usbMic, other])
        await coordinator.monitorDevices()
        #expect(coordinator.selectedDevices == [Fixtures.usbMic])

        let systemOnly = makeCoordinator(devices: [.systemAudio])
        await systemOnly.monitorDevices()
        #expect(systemOnly.selectedDevices == [.systemAudio])
    }

    @Test func reselectsPreferredDeviceWhenItReturns() async {
        let removal = makeCoordinator(
            updates: [[Fixtures.builtInMic, Fixtures.usbMic], [Fixtures.builtInMic]],
            preferredDeviceIDs: [Fixtures.usbMic.id]
        )
        await removal.monitorDevices()
        #expect(removal.selectedDevices == [Fixtures.builtInMic])
        #expect(removal.devices == [Fixtures.builtInMic])

        let comeback = makeCoordinator(
            updates: [[Fixtures.builtInMic], [Fixtures.builtInMic, Fixtures.usbMic]],
            preferredDeviceIDs: [Fixtures.usbMic.id]
        )
        await comeback.monitorDevices()
        #expect(comeback.selectedDevices == [Fixtures.usbMic])
    }

    @Test func selectDevicesIsIgnoredWhileRecordingOrEmpty() async {
        let coordinator = makeCoordinator()
        await coordinator.monitorDevices()
        #expect(coordinator.selectDevices([Fixtures.usbMic]))
        #expect(coordinator.selectedDevices == [Fixtures.usbMic])
        #expect(!coordinator.selectDevices([]))
        #expect(coordinator.selectedDevices == [Fixtures.usbMic])

        await coordinator.startRecording()
        #expect(coordinator.isRecording)
        #expect(!coordinator.selectDevices([Fixtures.builtInMic]))
        #expect(coordinator.selectedDevices == [Fixtures.usbMic])

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
        #expect(note.sources == [Fixtures.builtInMic])
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

    // MARK: - Multiple sources

    @Test func recordsSourcesSeparatelyAndMergesByTime() async throws {
        // The system audio starts a second after the microphone, according to the host clock.
        let microphone = MockCapture(chunks: [Fixtures.chunk(seconds: 2, hostTime: 100)])
        let systemAudio = MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 101)])
        let engine = MockEngine(transcriptsBySampleCount: [
            32_000: Transcript(segments: [TranscriptSegment(start: 0.2, end: 1, text: "Hello there.")], language: "en"),
            16_000: Transcript(segments: [TranscriptSegment(start: 0, end: 0.5, text: "Hi, how are you?")]),
        ])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [Fixtures.builtInMic.id: microphone, AudioInputDevice.systemAudioID: systemAudio],
            engine: engine,
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        #expect(coordinator.isRecording)
        await coordinator.stopRecording()

        #expect(coordinator.phase == .idle)
        #expect(microphone.stopCount == 1)
        #expect(systemAudio.stopCount == 1)
        #expect(await engine.receivedSampleCounts.sorted() == [16_000, 32_000])

        let note = try #require(await writer.notes.first)
        #expect(note.sources == [Fixtures.builtInMic, .systemAudio])
        #expect(note.duration == 2)
        #expect(
            note.transcript
                == Transcript(
                    segments: [
                        TranscriptSegment(start: 0.2, end: 1, text: "Hello there.", speaker: "Me"),
                        TranscriptSegment(start: 1, end: 1.5, text: "Hi, how are you?", speaker: "Others"),
                    ],
                    language: "en"
                )
        )
    }

    @Test func silentSourceIsNotTranscribed() async throws {
        let engine = MockEngine(
            transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "Just me.")])
        )
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            captures: [AudioInputDevice.systemAudioID: MockCapture()],
            engine: engine,
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        await coordinator.stopRecording()

        #expect(await engine.receivedSampleCounts == [16_000])
        let note = try #require(await writer.notes.first)
        #expect(note.sources == [Fixtures.builtInMic, .systemAudio])
        #expect(note.transcript.speakers == ["Me"])
    }

    // MARK: - Levels

    @Test func flagsSourcesThatStaySilent() async throws {
        let microphone = MockCapture(chunks: [Fixtures.chunk(seconds: 1)])
        // A tap without permission keeps delivering zeros.
        let systemAudio = MockCapture(chunks: [Fixtures.chunk(seconds: 1, amplitude: 0)])
        let coordinator = makeCoordinator(
            captures: [Fixtures.builtInMic.id: microphone, AudioInputDevice.systemAudioID: systemAudio],
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        coordinator.silenceWarningDelay = .milliseconds(50)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.inputLevels.count == 2 }
        #expect(coordinator.inputLevels[Fixtures.builtInMic.id] == InputLevel(peak: 0.1))
        #expect(coordinator.inputLevels[AudioInputDevice.systemAudioID] == InputLevel(peak: 0))
        #expect(coordinator.silentDevices.isEmpty)

        try await waitUntil { !coordinator.silentDevices.isEmpty }
        #expect(coordinator.silentDevices == [.systemAudio])

        await coordinator.stopRecording()
        #expect(coordinator.inputLevels.isEmpty)
        #expect(coordinator.silentDevices.isEmpty)
    }

    @Test func sourceThatIsHeardLeavesSilentList() async throws {
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1, amplitude: 0)])
        let coordinator = makeCoordinator(capture: capture)
        coordinator.silenceWarningDelay = .milliseconds(50)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.silentDevices == [Fixtures.builtInMic] }

        capture.yield(Fixtures.chunk(seconds: 0.1, startTime: 1))
        try await waitUntil { coordinator.silentDevices.isEmpty }
        #expect(coordinator.inputLevels[Fixtures.builtInMic.id] == InputLevel(peak: 0.1))

        await coordinator.stopRecording()
    }

    @Test func sourceFailingToStartStopsTheOthers() async {
        let error = AudioCaptureError.deviceUnavailable("Couldn't create the system audio tap")
        let microphone = MockCapture()
        let coordinator = makeCoordinator(
            captures: [
                Fixtures.builtInMic.id: microphone, AudioInputDevice.systemAudioID: MockCapture(startError: error),
            ],
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()

        #expect(coordinator.phase == .failed(message: error.localizedDescription))
        #expect(!coordinator.isRecording)
        #expect(microphone.stopCount == 1)
        #expect(coordinator.canStartRecording)
    }

    @Test func sourceEndingStopsWholeRecording() async throws {
        let microphone = MockCapture(chunks: [Fixtures.chunk(seconds: 1)])
        let systemAudio = MockCapture(chunks: [Fixtures.chunk(seconds: 1)], finishesOnStart: true)
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [Fixtures.builtInMic.id: microphone, AudioInputDevice.systemAudioID: systemAudio],
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.lastNoteURL != nil }

        #expect(coordinator.phase == .idle)
        #expect(microphone.stopCount == 1)
        #expect(await writer.notes.first?.sources == [Fixtures.builtInMic, .systemAudio])
    }

    @Test func labelsUseConfiguredNames() async throws {
        let engine = MockEngine(transcriptsBySampleCount: [
            16_000: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "Hello.")]),
            32_000: Transcript(segments: [TranscriptSegment(start: 1, end: 2, text: "Good morning.")]),
        ])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            captures: [AudioInputDevice.systemAudioID: MockCapture(chunks: [Fixtures.chunk(seconds: 2)])],
            engine: engine,
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        coordinator.sourceLabels = SourceLabels(microphone: "Martin", systemAudio: " ")
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        await coordinator.stopRecording()

        let note = try #require(await writer.notes.first)
        #expect(note.transcript.speakers == ["Martin", SourceLabels.defaultSystemAudio])
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

    @Test func recordingWaitsForModelDownload() async {
        let factory = MockCaptureFactory(capture: MockCapture())
        let coordinator = RecordingCoordinator(
            deviceProvider: MockDeviceProvider(devices: Fixtures.devices),
            captureFactory: factory,
            engine: MockEngine(isDownloaded: false),
            noteWriter: InMemoryNoteWriter()
        )
        await coordinator.monitorDevices()

        #expect(!coordinator.isModelDownloaded)
        #expect(coordinator.isIdle)
        #expect(!coordinator.canStartRecording)
        await coordinator.startRecording()
        #expect(coordinator.phase == .idle)
        #expect(factory.requestedDevices.current.isEmpty)

        await coordinator.prepareEngine()

        #expect(coordinator.isModelDownloaded)
        #expect(coordinator.canStartRecording)
        await coordinator.startRecording()
        #expect(coordinator.isRecording)
    }

    @Test func recordingWaitsForNotesFolder() async {
        let coordinator = makeCoordinator()
        coordinator.noteWriter = nil
        await coordinator.monitorDevices()

        #expect(!coordinator.canStartRecording)
        await coordinator.startRecording()
        #expect(coordinator.phase == .idle)

        coordinator.noteWriter = InMemoryNoteWriter()
        #expect(coordinator.canStartRecording)
    }

    @Test func notesFolderGoingAwayMidRecordingFails() async {
        let coordinator = makeCoordinator(capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]))
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        coordinator.noteWriter = nil
        await coordinator.stopRecording()

        #expect(coordinator.phase == .failed(message: NoteWritingError.noFolder.localizedDescription))
        #expect(coordinator.lastNoteURL == nil)
    }

    @Test func failedOrCancelledDownloadKeepsRecordingDisabled() async throws {
        let failing = makeCoordinator(
            engine: MockEngine(isDownloaded: false, prepareError: TranscriptionError.modelUnavailable("offline"))
        )
        await failing.monitorDevices()
        await failing.prepareEngine()
        #expect(!failing.isModelDownloaded)
        #expect(!failing.canStartRecording)

        let cancelled = makeCoordinator(engine: MockEngine(isDownloaded: false, preparesUntilCancelled: true))
        await cancelled.monitorDevices()
        let preparing = Task { await cancelled.prepareEngine() }
        try await waitUntil { cancelled.isBusy }
        #expect(!cancelled.isIdle)
        cancelled.cancelPreparation()
        await preparing.value
        #expect(!cancelled.isModelDownloaded)
        #expect(!cancelled.canStartRecording)
    }

    @Test func deletingModelDisablesRecordingUntilDownloadedAgain() async {
        let engine = MockEngine()
        let coordinator = makeCoordinator(engine: engine)
        await coordinator.monitorDevices()
        #expect(coordinator.canStartRecording)

        await coordinator.deleteModel()

        #expect(await engine.deleteCount == 1)
        #expect(!coordinator.isModelDownloaded)
        #expect(!coordinator.isDeletingModel)
        #expect(coordinator.phase == .idle)
        #expect(!coordinator.canStartRecording)

        // Nothing left to delete.
        await coordinator.deleteModel()
        #expect(await engine.deleteCount == 1)

        await coordinator.prepareEngine()
        #expect(coordinator.canStartRecording)
    }

    @Test func failedDeleteShowsError() async {
        let error = TranscriptionError.failed("permission denied")
        let coordinator = makeCoordinator(engine: MockEngine(deleteError: error))

        await coordinator.deleteModel()

        #expect(coordinator.phase == .failed(message: error.localizedDescription))
        #expect(coordinator.isModelDownloaded)
    }

    @Test func deleteModelIgnoredWhileRecording() async {
        let engine = MockEngine()
        let coordinator = makeCoordinator(engine: engine)
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        #expect(coordinator.isRecording)

        await coordinator.deleteModel()

        #expect(await engine.deleteCount == 0)
        #expect(coordinator.isModelDownloaded)
        await coordinator.stopRecording()
    }

    @Test func cancelPreparationIgnoresOtherPhases() async {
        let error = TranscriptionError.modelUnavailable("offline")
        let coordinator = makeCoordinator(engine: MockEngine(prepareError: error))
        await coordinator.prepareEngine()

        coordinator.cancelPreparation()

        #expect(coordinator.phase == .failed(message: error.localizedDescription))
    }
}
