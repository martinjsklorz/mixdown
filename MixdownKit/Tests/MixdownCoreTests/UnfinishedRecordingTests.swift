import Foundation
import Testing

@testable import MixdownCore

/// Recordings kept on disk until their notes are saved, and made into notes after a quit or a
/// failed transcription.
@MainActor
struct UnfinishedRecordingTests {
    private func makeCoordinator(
        store: RecordingStore,
        capture: MockCapture = MockCapture(),
        captures: [String: MockCapture] = [:],
        engine: MockEngine = MockEngine(),
        writer: (any NoteWriting)? = InMemoryNoteWriter(),
        pendingNotes: [Note] = [],
        preferredDeviceIDs: [String] = [],
        keepsAudioOnDisk: Bool = true
    ) -> RecordingCoordinator {
        let coordinator = RecordingCoordinator(
            deviceProvider: MockDeviceProvider(devices: Fixtures.devices),
            captureFactory: MockCaptureFactory(capture: capture, captures: captures),
            engine: engine,
            noteWriter: writer,
            pendingNotes: pendingNotes,
            preferredDeviceIDs: preferredDeviceIDs,
            recordingStore: store,
            now: { Fixtures.startDate }
        )
        coordinator.keepsAudioOnDisk = keepsAudioOnDisk
        return coordinator
    }

    @Test func recordingIsKeptOnDiskUntilItsNoteIsSaved() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1)])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(store: store, capture: capture, writer: writer)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        #expect(!coordinator.isMakingNote)
        #expect(coordinator.keepsRecordingWhenQuitting)
        try await waitUntil { store.recordings().first?.duration == 1 }
        capture.yield(Fixtures.chunk(seconds: 1))
        try await waitUntil { store.recordings().first?.duration == 2 }
        #expect(store.recordings().first?.sources == [Fixtures.builtInMic].map(Self.stored))

        await coordinator.stopRecording()

        #expect(coordinator.phase == .idle)
        #expect(await writer.notes.count == 1)
        #expect(store.recordings().isEmpty)
        #expect(coordinator.unfinishedRecordings.isEmpty)
    }

    @Test func failedTranscriptionKeepsTheRecordingToTranscribeAgain() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let error = TranscriptionError.failed("boom")
        let failing = makeCoordinator(
            store: store,
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1), Fixtures.chunk(seconds: 0.5, amplitude: 0.2)]),
            engine: MockEngine(transcribeError: error)
        )
        await failing.monitorDevices()
        await failing.startRecording()
        await failing.stopRecording()

        let recording = try #require(failing.unfinishedRecordings.first)
        #expect(failing.phase == .failed(message: keepingRecording(error.localizedDescription, in: failing)))
        #expect(failing.unfinishedRecordings.count == 1)
        #expect(recording.isOnDisk)
        #expect(recording.startedAt == Fixtures.startDate)
        #expect(recording.duration == 1.5)
        #expect(recording.sources == [Fixtures.builtInMic])

        // The next launch, with a model that works.
        let transcript = Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "Hello.")])
        let engine = MockEngine(transcript: transcript)
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(store: store, engine: engine, writer: writer)
        #expect(coordinator.unfinishedRecordings.map(\.id) == [recording.id])
        #expect(coordinator.canTranscribeUnfinishedRecordings)

        await coordinator.transcribe(coordinator.unfinishedRecordings[0])

        #expect(coordinator.phase == .idle)
        #expect(
            await engine.receivedSamples
                == [Fixtures.chunk(seconds: 1).samples + Fixtures.chunk(seconds: 0.5, amplitude: 0.2).samples]
        )
        let note = try #require(await writer.notes.first)
        #expect(note.transcript == transcript)
        #expect(note.createdAt == Fixtures.startDate)
        #expect(note.duration == 1.5)
        #expect(note.sources == [Fixtures.builtInMic].map(Self.stored))
        #expect(coordinator.unfinishedRecordings.isEmpty)
        #expect(!coordinator.isTranscribingUnfinishedRecording)
        #expect(store.recordings().isEmpty)
        #expect(engine.recordingsInProgress.current == 0)
    }

    @Test func recordingStoppedWithoutANoteKeepsItsCallAndMoments() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let quitting = makeCoordinator(
            store: store,
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 2)]),
            engine: MockEngine()
        )
        await quitting.monitorDevices()
        await quitting.startRecording()
        try await waitUntil { store.recordings().first?.duration == 2 }
        quitting.markRecordingAsCall(automatically: true)
        quitting.addMoment(at: 1, text: "Budget")

        await quitting.stopRecordingWithoutNote()

        #expect(quitting.phase == .idle)
        #expect(!quitting.isRecording)
        #expect(quitting.moments.isEmpty)
        #expect(quitting.unfinishedRecordings.map(\.duration) == [2])

        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(store: store, writer: writer)
        await coordinator.transcribe(try #require(coordinator.unfinishedRecordings.first))

        let note = try #require(await writer.notes.first)
        #expect(note.isCall)
        #expect(note.trigger == .automatic)
        #expect(note.moments.map(\.text) == ["Budget"])
        #expect(note.moments.map(\.time) == [1])
    }

    @Test func stoppingWithoutANoteReleasesTheEngine() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let engine = MockEngine()
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            store: store,
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            engine: engine,
            writer: writer
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        await coordinator.stopRecordingWithoutNote()

        #expect(engine.recordingsInProgress.current == 0)
        #expect(await engine.receivedSampleCounts.isEmpty)
        #expect(await writer.notes.isEmpty)
        #expect(coordinator.canStartRecording)
    }

    @Test func trackFailingToTranscribeKeepsTheRecordingAlongsideTheNote() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let error = TranscriptionError.failed("boom")
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            store: store,
            captures: [
                Fixtures.builtInMic.id: MockCapture(chunks: [Fixtures.chunk(seconds: 2, hostTime: 100)]),
                AudioInputDevice.systemAudioID: MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)]),
            ],
            engine: MockEngine(
                transcriptsBySampleCount: [
                    32_000: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "Hello there.")])
                ],
                transcribeErrorsBySampleCount: [16_000: error]
            ),
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        await coordinator.stopRecording()

        #expect(await writer.notes.count == 1)
        let untranscribed = RecordingCoordinator.untranscribedMessage(for: [.systemAudio], error: error)
        #expect(coordinator.phase == .failed(message: keepingRecording(untranscribed, in: coordinator)))
        #expect(coordinator.unfinishedRecordings.map(\.duration) == [2])
        #expect(store.recordings().count == 1)
    }

    @Test func pendingNoteKeepsItsRecordingUntilItsSaved() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let old = makeCoordinator(store: store, capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]))
        await old.monitorDevices()
        await old.startRecording()
        old.noteWriter = nil
        await old.stopRecording()

        #expect(old.pendingNotes.count == 1)
        #expect(old.unfinishedRecordings.isEmpty)
        #expect(store.recordings().count == 1)

        // Moved to the next coordinator, like on a model switch: still not unfinished.
        let pending = old.takePendingNotes()
        let new = makeCoordinator(store: store, writer: nil, pendingNotes: pending)
        #expect(new.unfinishedRecordings.isEmpty)

        let writer = InMemoryNoteWriter()
        new.noteWriter = writer
        try await waitUntil { new.pendingNotes.isEmpty }
        #expect(await writer.notes.count == 1)
        #expect(store.recordings().isEmpty)
    }

    @Test func tooShortRecordingIsDeleted() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let coordinator = makeCoordinator(store: store, capture: MockCapture(chunks: [Fixtures.chunk(seconds: 0.25)]))
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        await coordinator.stopRecording()

        #expect(coordinator.phase == .failed(message: RecordingCoordinator.tooShortMessage))
        #expect(coordinator.unfinishedRecordings.isEmpty)
        #expect(store.recordings().isEmpty)
    }

    @Test func discardingDeletesTheRecording() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let coordinator = makeCoordinator(
            store: store,
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            engine: MockEngine(transcribeError: TranscriptionError.failed("boom"))
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        await coordinator.stopRecording()
        let recording = try #require(coordinator.unfinishedRecordings.first)

        coordinator.discard(recording)

        #expect(coordinator.unfinishedRecordings.isEmpty)
        #expect(store.recordings().isEmpty)
        #expect(makeCoordinator(store: store).unfinishedRecordings.isEmpty)
    }

    @Test func withoutDiskAFailedRecordingIsKeptInMemoryOnly() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let error = TranscriptionError.failed("boom")
        let engine = MockEngine(transcribeError: error)
        let coordinator = makeCoordinator(
            store: store,
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            engine: engine,
            keepsAudioOnDisk: false
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        #expect(!coordinator.keepsRecordingWhenQuitting)
        await coordinator.stopRecording()

        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        let recording = try #require(coordinator.unfinishedRecordings.first)
        #expect(!recording.isOnDisk)
        #expect(recording.duration == 1)
        #expect(
            coordinator.phase
                == .failed(
                    message: "\(error.localizedDescription) "
                        + "Mixdown kept the recording until it quits, so you can transcribe it again from Record."
                )
        )
        #expect(makeCoordinator(store: store).unfinishedRecordings.isEmpty)

        // Failing again, it's still kept, with its audio.
        await coordinator.transcribe(recording)
        #expect(coordinator.unfinishedRecordings == [recording])
        #expect(await engine.receivedSamples == Array(repeating: Fixtures.chunk(seconds: 1).samples, count: 2))

        // Handed to the next coordinator, like on a model switch, and transcribed there.
        let writer = InMemoryNoteWriter()
        let next = RecordingCoordinator(
            deviceProvider: MockDeviceProvider(devices: Fixtures.devices),
            captureFactory: MockCaptureFactory(capture: MockCapture()),
            engine: MockEngine(),
            noteWriter: writer,
            recordingsInMemory: coordinator.takeRecordingsInMemory(),
            recordingStore: store,
            now: { Fixtures.startDate }
        )
        #expect(coordinator.unfinishedRecordings.isEmpty)
        #expect(coordinator.recordingsInMemory.isEmpty)
        #expect(next.unfinishedRecordings == [recording])

        await next.transcribe(recording)
        #expect(await writer.notes.count == 1)
        #expect(next.unfinishedRecordings.isEmpty)
        #expect(next.recordingsInMemory.isEmpty)
    }

    @Test func discardingARecordingInMemoryLetsGoOfItsAudio() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let coordinator = makeCoordinator(
            store: store,
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            engine: MockEngine(transcribeError: TranscriptionError.failed("boom")),
            keepsAudioOnDisk: false
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        await coordinator.stopRecording()

        coordinator.discard(try #require(coordinator.unfinishedRecordings.first))

        #expect(coordinator.unfinishedRecordings.isEmpty)
        #expect(coordinator.recordingsInMemory.isEmpty)
    }

    @Test func withoutDiskARecordingsAudioIsLetGoOnceItsNoteIsMade() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            store: store,
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            writer: writer,
            keepsAudioOnDisk: false
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        await coordinator.stopRecording()

        #expect(coordinator.phase == .idle)
        #expect(await writer.notes.count == 1)
        #expect(coordinator.unfinishedRecordings.isEmpty)
        #expect(coordinator.recordingsInMemory.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    /// Devices as the store keeps them, which doesn't say which was the default.
    private static func stored(_ device: AudioInputDevice) -> AudioInputDevice {
        AudioInputDevice(id: device.id, name: device.name, kind: device.kind)
    }
}
