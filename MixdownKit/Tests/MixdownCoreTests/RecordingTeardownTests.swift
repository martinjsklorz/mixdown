import Foundation
import Testing

@testable import MixdownCore

/// Stopping a recording: the time it takes its inputs to stop, pausing in quick succession, and
/// what's kept of it when its audio couldn't all be written to disk.
@MainActor
struct RecordingTeardownTests {
    /// A coordinator that records from `captures`, in the order they're started.
    private func makeCoordinator(
        store: RecordingStore? = nil,
        captures: [any AudioCapturing] = [],
        engine: any TranscriptionEngine = MockEngine(),
        writer: InMemoryNoteWriter = InMemoryNoteWriter(),
        preferredDeviceIDs: [String] = []
    ) -> RecordingCoordinator {
        RecordingCoordinator(
            deviceProvider: MockDeviceProvider(devices: Fixtures.devices),
            captureFactory: SequenceCaptureFactory(captures: captures),
            engine: engine,
            noteWriter: writer,
            preferredDeviceIDs: preferredDeviceIDs,
            recordingStore: store,
            now: { Fixtures.startDate }
        )
    }

    // MARK: - Stopping

    @Test func recordingThatIsStoppingNoLongerCountsAsRecordingButIsKeptWhenQuitting() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let capture = StallingCapture(chunks: [Fixtures.chunk(seconds: 1)])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(store: store, captures: [capture], writer: writer)
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        try await waitUntil { store.recordings().first?.duration == 1 }

        let stopping = Task { await coordinator.stopRecording() }
        try await waitUntil { capture.stopCount == 1 }

        #expect(!coordinator.isRecording)
        #expect(!coordinator.canStopRecording)
        #expect(coordinator.momentTime == nil)
        #expect(coordinator.keepsRecordingWhenQuitting)
        // Logging out doesn't wait for a note that's kept on disk anyway.
        #expect(coordinator.quitPlan(isSessionEnding: true) == .quitNow)
        #expect(
            coordinator.quitPlan(isSessionEnding: false) == .askWhileMakingNote(importing: nil, keepsRecording: true)
        )
        // A moment the user was still typing goes into the note.
        let moment = try #require(coordinator.addMoment(at: 0.5, text: "Late"))
        await coordinator.pauseRecording()
        #expect(!coordinator.isPaused)

        await capture.stopGate.open()
        await stopping.value
        #expect(coordinator.phase == .idle)
        #expect(await writer.notes.first?.moments == [moment])
        #expect(!coordinator.keepsRecordingWhenQuitting)
    }

    @Test func recordingOnlyInMemoryIsWaitedForWhileItStops() async throws {
        let capture = StallingCapture(chunks: [Fixtures.chunk(seconds: 1)])
        let coordinator = makeCoordinator(captures: [capture])
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        let stopping = Task { await coordinator.stopRecording() }
        try await waitUntil { capture.stopCount == 1 }

        #expect(!coordinator.keepsRecordingWhenQuitting)
        #expect(coordinator.quitPlan(isSessionEnding: true) == .quitWhenDone)

        await capture.stopGate.open()
        await stopping.value
        #expect(coordinator.quitPlan(isSessionEnding: true) == .quitNow)
    }

    @Test func stoppingWithoutANoteDoesNotWaitForLiveTranscriptionToCatchUp() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        // 31 pieces for the live session, which takes a second over each.
        let live = SlowLiveSession(pushDelay: .seconds(1))
        let coordinator = makeCoordinator(
            store: store,
            captures: [MockCapture(chunks: [Fixtures.chunk(seconds: 10)])],
            engine: LiveEngine(session: live)
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        try await waitUntil { store.recordings().first?.duration == 10 }
        try await waitUntil { live.pushCount == 1 }

        let clock = ContinuousClock()
        let start = clock.now
        await coordinator.stopRecordingWithoutNote()

        #expect(clock.now - start < .seconds(1))
        #expect(live.pushCount < 31)
        #expect(await live.finishCount == 0)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.unfinishedRecordings.map(\.duration) == [10])
    }

    // MARK: - Pausing

    @Test func resumingAgainWaitsForTheFirstPauseToStopItsInputs() async throws {
        let first = StallingCapture(chunks: [Fixtures.chunk(seconds: 1)])
        let second = MockCapture()
        let coordinator = makeCoordinator(
            captures: [first, second]
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        let pausing = Task { await coordinator.pauseRecording() }
        try await waitUntil { first.stopCount == 1 }
        let resuming = Task { await coordinator.resumeRecording() }
        try await waitUntil { !coordinator.isPaused }
        let pausingAgain = Task { await coordinator.pauseRecording() }
        try await waitUntil { coordinator.isPaused }
        let resumingAgain = Task { await coordinator.resumeRecording() }
        try await waitUntil { !coordinator.isPaused }
        try await Task.sleep(for: .milliseconds(50))
        // The device hasn't stopped from the first pause yet.
        #expect(second.startCount == 0)

        await first.stopGate.open()
        try await waitUntil { second.startCount == 1 }
        await pausing.value
        await resuming.value
        await pausingAgain.value
        await resumingAgain.value
        #expect(second.startCount == 1)
        await coordinator.stopRecording()
    }

    // MARK: - Disk

    @Test func recordingWhoseAudioCouldNotAllBeWrittenIsKeptInMemory() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let capture = MockCapture()
        let coordinator = makeCoordinator(
            store: store,
            captures: [capture],
            engine: MockEngine(transcribeError: TranscriptionError.failed("boom"))
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        // The disk fills up before any audio is written.
        let folder = try #require(
            try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).first
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        capture.yield(Fixtures.chunk(seconds: 2))
        try await Task.sleep(for: .milliseconds(50))

        await coordinator.stopRecording()

        let recording = try #require(coordinator.unfinishedRecordings.first)
        #expect(!recording.isOnDisk)
        #expect(recording.duration == 2)
        #expect(coordinator.recordingsInMemory[recording.id]?.lanes.map(\.audio.track.samples.count) == [32_000])
        #expect(
            coordinator.quitPlan(isSessionEnding: false) == .askAboutLosingWork(pendingNotes: 0, recordingsInMemory: 1)
        )
    }

    // MARK: - Making a note later

    @Test func recordingMadeIntoANoteLaterHasItsTalkTimeline() async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let microphone = MockCapture(
            chunks: [AudioChunk(samples: TalkFixtures.audio([true, false, true]), hostTime: 100)]
        )
        let systemAudio = MockCapture(
            chunks: [AudioChunk(samples: TalkFixtures.audio([false, true, true]), hostTime: 101)]
        )
        let quitting = makeCoordinator(
            store: store,
            captures: [microphone, systemAudio],
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        quitting.measuresTalkTime = true
        await quitting.monitorDevices()
        await quitting.startRecording()
        try await waitUntil { store.recordings().first?.duration == 4 }
        await quitting.stopRecordingWithoutNote()

        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(store: store, writer: writer)
        await coordinator.transcribe(try #require(coordinator.unfinishedRecordings.first))

        let timeline = try #require(await writer.notes.first?.talkTimeline)
        #expect(abs(timeline.microphone[0] - 2) < 0.001)
        #expect(abs(timeline.systemAudio[0] - 2) < 0.001)
    }

    @Test(arguments: [false, true])
    func recordingMadeIntoANoteLaterTellsSpeakersApartOnlyIfItWasToBe(identifiedSpeakers: Bool) async throws {
        let store = RecordingStoreTests.makeStore()
        defer { RecordingStoreTests.remove(store) }
        let quitting = makeCoordinator(
            store: store,
            captures: [MockCapture(chunks: [Fixtures.chunk(seconds: 1)])],
            preferredDeviceIDs: [AudioInputDevice.systemAudioID]
        )
        quitting.speakerDiarizer = identifiedSpeakers ? MockDiarizer() : nil
        await quitting.monitorDevices()
        await quitting.startRecording()
        try await waitUntil { store.recordings().first?.duration == 1 }
        await quitting.stopRecordingWithoutNote()

        let diarizer = MockDiarizer()
        let transcript = Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "Hello.")])
        let coordinator = makeCoordinator(store: store, engine: MockEngine(transcript: transcript))
        coordinator.speakerDiarizer = diarizer
        await coordinator.transcribe(try #require(coordinator.unfinishedRecordings.first))

        #expect(coordinator.phase == .idle)
        #expect(diarizer.receivedSampleCounts == (identifiedSpeakers ? [16_000] : []))
    }
}

/// Hands out `captures` one after another, whichever the device, then captures that record nothing.
private struct SequenceCaptureFactory: AudioCaptureFactory {
    let captures: LockedValue<[any AudioCapturing]>

    init(captures: [any AudioCapturing]) {
        self.captures = LockedValue(captures)
    }

    func makeCapture(for device: AudioInputDevice) throws -> any AudioCapturing {
        var next: (any AudioCapturing)?
        captures.update { captures in
            if !captures.isEmpty { next = captures.removeFirst() }
        }
        return next ?? MockCapture()
    }
}
