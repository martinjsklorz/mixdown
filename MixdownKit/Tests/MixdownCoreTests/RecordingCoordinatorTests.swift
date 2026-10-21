import Foundation
import Testing

@testable import MixdownCore

@MainActor
struct RecordingCoordinatorTests {
    private func makeCoordinator(
        devices: [AudioInputDevice] = Fixtures.devices,
        updates: [[AudioInputDevice]] = [],
        deviceProvider: (any AudioDeviceProvider)? = nil,
        capture: MockCapture = MockCapture(),
        captures: [String: MockCapture] = [:],
        queuedCaptures: [String: [MockCapture]] = [:],
        engine: any TranscriptionEngine = MockEngine(),
        writer: InMemoryNoteWriter = InMemoryNoteWriter(),
        summarizer: MockSummarizer? = nil,
        options: TranscriptionOptions = .init(),
        preferredDeviceIDs: [String] = [],
        playbackMonitor: MockPlaybackMonitor? = nil,
        echoCancellation: (any EchoCancellation)? = nil,
        now: @escaping @Sendable () -> Date = { Fixtures.startDate },
        hostClock: @escaping @Sendable () -> TimeInterval = { 0 }
    ) -> RecordingCoordinator {
        let coordinator = RecordingCoordinator(
            deviceProvider: deviceProvider ?? MockDeviceProvider(devices: devices, updates: updates),
            captureFactory: MockCaptureFactory(capture: capture, captures: captures, queuedCaptures: queuedCaptures),
            engine: engine,
            noteWriter: writer,
            summarizer: summarizer,
            options: options,
            preferredDeviceIDs: preferredDeviceIDs,
            playbackMonitor: playbackMonitor,
            echoCancellation: echoCancellation,
            now: now,
            hostClock: hostClock
        )
        coordinator.deviceSwitchDelay = .zero
        return coordinator
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

    /// A device list, the preferred device IDs, and what they resolve to.
    struct SelectionCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        var devices = Fixtures.devices
        var preferred: [String] = []
        let expected: [AudioInputDevice]
    }

    @Test(arguments: [
        SelectionCase(
            testDescription: "preferred device",
            preferred: [AudioInputDevice.systemAudioID],
            expected: [.systemAudio]
        ),
        SelectionCase(
            testDescription: "in device-list order, not preference order",
            preferred: [AudioInputDevice.systemAudioID, Fixtures.usbMic.id],
            expected: [Fixtures.usbMic, .systemAudio]
        ),
        SelectionCase(
            testDescription: "missing microphone falls back to the default",
            preferred: ["unplugged"],
            expected: [Fixtures.builtInMic]
        ),
        SelectionCase(
            testDescription: "missing microphone falls back to the default alongside system audio",
            preferred: ["unplugged", AudioInputDevice.systemAudioID],
            expected: [Fixtures.builtInMic, .systemAudio]
        ),
        SelectionCase(
            testDescription: "missing system audio is dropped",
            devices: [Fixtures.usbMic, Fixtures.builtInMic],
            preferred: [Fixtures.usbMic.id, AudioInputDevice.systemAudioID],
            expected: [Fixtures.usbMic]
        ),
        SelectionCase(
            testDescription: "first microphone without a default",
            devices: [Fixtures.usbMic, AudioInputDevice(id: "other", name: "Other", kind: .microphone)],
            expected: [Fixtures.usbMic]
        ),
        SelectionCase(
            testDescription: "system audio when it's all there is",
            devices: [.systemAudio],
            expected: [.systemAudio]
        ),
    ])
    func resolvesSelection(_ selection: SelectionCase) async {
        let coordinator = makeCoordinator(devices: selection.devices, preferredDeviceIDs: selection.preferred)
        await coordinator.monitorDevices()
        #expect(coordinator.selectedDevices == selection.expected)
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

    @Test func systemDefaultFollowsTheDefaultMicrophone() async {
        let coordinator = makeCoordinator(
            updates: [[Fixtures.usbMicAsDefault, Fixtures.builtInMicNotDefault, .systemAudio]],
            preferredDeviceIDs: [AudioInputDevice.defaultMicrophoneID, AudioInputDevice.systemAudioID]
        )
        #expect(coordinator.followsDefaultMicrophone)

        await coordinator.monitorDevices()

        #expect(coordinator.selectedDevices == [Fixtures.usbMicAsDefault, .systemAudio])
    }

    @Test func choosingSystemDefaultOrADevice() async {
        let coordinator = makeCoordinator(preferredDeviceIDs: [Fixtures.usbMic.id])
        await coordinator.monitorDevices()
        #expect(!coordinator.followsDefaultMicrophone)

        #expect(coordinator.selectDevices([.defaultMicrophone, .systemAudio]))
        #expect(coordinator.followsDefaultMicrophone)
        #expect(coordinator.selectedDevices == [Fixtures.builtInMic, .systemAudio])

        coordinator.selectDevices([.systemAudio])
        #expect(!coordinator.followsDefaultMicrophone)
        #expect(coordinator.selectedDevices == [.systemAudio])

        // Nothing chosen yet behaves as System Default.
        #expect(makeCoordinator().followsDefaultMicrophone)
    }

    @Test func selectDevicesIsIgnoredWhenEmpty() async {
        let coordinator = makeCoordinator()
        await coordinator.monitorDevices()
        #expect(coordinator.selectDevices([Fixtures.usbMic]))
        #expect(coordinator.selectedDevices == [Fixtures.usbMic])
        #expect(!coordinator.selectDevices([]))
        #expect(coordinator.selectedDevices == [Fixtures.usbMic])

        await coordinator.startRecording()
        #expect(!coordinator.selectDevices([]))
        #expect(coordinator.selectedDevices == [Fixtures.usbMic])

        await coordinator.stopRecording()
        // The mocks record nothing.
        #expect(coordinator.phase == .failed(message: RecordingCoordinator.tooShortMessage))
    }

    // MARK: - Recording

    @Test func startAndStopWritesNote() async throws {
        let capture = MockCapture(chunks: [
            Fixtures.chunk(seconds: 1),
            Fixtures.chunk(seconds: 1),
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
        #expect(!coordinator.showsLiveTranscript)

        await coordinator.stopRecording()

        #expect(coordinator.phase == .idle)
        #expect(capture.stopCount == 1)
        #expect(await engine.receivedSampleCounts == [32_000])
        // The model was on disk, so it isn't prepared first.
        #expect(await engine.prepareCount == 0)

        let notes = await writer.notes
        #expect(notes.count == 1)
        let note = try #require(notes.first)
        #expect(note.transcript == transcript)
        #expect(note.transcript.text == "Hello world")
        #expect(note.duration == 2)
        #expect(note.sources == [Fixtures.builtInMic])
        #expect(note.createdAt == Fixtures.startDate)
        #expect(note.engine == engine.info)
        // Without a summarizer.
        #expect(note.summary == nil)
        #expect(note.title.hasPrefix("Recording "))
        #expect(coordinator.lastNoteURL == URL(fileURLWithPath: "/tmp/mixdown-test-1.md"))
    }

    @Test func engineKeepsModelFromStartUntilTranscribed() async {
        let engine = MockEngine()
        let coordinator = makeCoordinator(capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]), engine: engine)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        #expect(engine.recordingsInProgress.current == 1)

        await coordinator.stopRecording()
        #expect(await engine.recordingsInProgressWhileTranscribing == [1])
        #expect(engine.recordingsInProgress.current == 0)
    }

    @Test func stopWhileStartingDiscardsTheRecordingQuietly() async throws {
        let gate = Gate()
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1)], startGate: gate)
        let engine = MockEngine()
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(capture: capture, engine: engine, writer: writer)
        await coordinator.monitorDevices()

        let starting = Task { await coordinator.startRecording() }
        try await waitUntil { capture.startCount == 1 }
        #expect(coordinator.phase == .startingCapture)
        #expect(!coordinator.isRecording)
        #expect(coordinator.canStopRecording)
        #expect(!coordinator.canStartRecording)

        #expect(!coordinator.isStopPending)

        await coordinator.stopRecording()
        #expect(coordinator.phase == .startingCapture)
        #expect(coordinator.isStopPending)

        await gate.open()
        await starting.value
        // Not "too short": nothing was recorded, so there's nothing to report.
        #expect(coordinator.phase == .idle)
        #expect(!coordinator.isStopPending)
        #expect(capture.stopCount == 1)
        #expect(await writer.notes.isEmpty)
        #expect(await engine.receivedSampleCounts.isEmpty)
        #expect(engine.recordingsInProgress.current == 0)
        #expect(coordinator.canStartRecording)
    }

    @Test func toggleWhileStartingStopsOnceStarted() async throws {
        let gate = Gate()
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1)], startGate: gate)
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(capture: capture, writer: writer)
        await coordinator.monitorDevices()

        let starting = Task { await coordinator.toggleRecording() }
        try await waitUntil { capture.startCount == 1 }
        await coordinator.toggleRecording()

        await gate.open()
        await starting.value
        #expect(coordinator.phase == .idle)
        #expect(capture.startCount == 1)
        #expect(await writer.notes.isEmpty)
    }

    @Test func stopWhileStartingIsForgottenWhenStartFails() async throws {
        let gate = Gate()
        let error = AudioCaptureError.microphonePermissionDenied
        let failing = MockCapture(startError: error, startGate: gate)
        let next = MockCapture(chunks: [Fixtures.chunk(seconds: 1)])
        let coordinator = makeCoordinator(queuedCaptures: [Fixtures.builtInMic.id: [failing, next]])
        await coordinator.monitorDevices()

        let starting = Task { await coordinator.startRecording() }
        try await waitUntil { failing.startCount == 1 }
        await coordinator.stopRecording()
        await gate.open()
        await starting.value
        #expect(coordinator.phase == .failed(message: error.localizedDescription))

        // The stop doesn't carry over to the next recording.
        await coordinator.startRecording()
        #expect(coordinator.isRecording)
        await coordinator.stopRecording()
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

        #expect(coordinator.phase == .failed(message: RecordingCoordinator.tooShortMessage))
        #expect(coordinator.modelError == nil)
        #expect(coordinator.lastNoteURL == nil)
        #expect(await engine.receivedSampleCounts.isEmpty)
        #expect(await writer.notes.isEmpty)
        #expect(engine.recordingsInProgress.current == 0)
        #expect(coordinator.canStartRecording)

        coordinator.dismissError()
        #expect(coordinator.phase == .idle)
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
        #expect(coordinator.modelError == nil)
        #expect(coordinator.lastNoteURL == nil)
        #expect(await writer.notes.isEmpty)
    }

    @Test func modelLoadErrorWhileTranscribingIsAModelError() async {
        let error = TranscriptionError.modelUnavailable("corrupt weights")
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            engine: MockEngine(transcribeError: error)
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        await coordinator.stopRecording()

        #expect(coordinator.phase == .failed(message: error.localizedDescription))
        #expect(coordinator.modelError == error.localizedDescription)
    }

    @Test func startErrorFailsAndDismissReturnsToIdle() async {
        let error = AudioCaptureError.microphonePermissionDenied
        let engine = MockEngine()
        let coordinator = makeCoordinator(capture: MockCapture(startError: error), engine: engine)
        await coordinator.monitorDevices()

        await coordinator.startRecording()

        #expect(coordinator.phase == .failed(message: error.localizedDescription))
        #expect(engine.recordingsInProgress.current == 0)
        #expect(coordinator.modelError == nil)
        #expect(!coordinator.isRecording)
        #expect(coordinator.canStartRecording)

        coordinator.dismissError()
        #expect(coordinator.phase == .idle)
    }

    @Test func captureErrorMidRecordingSavesNoteOfPartialRecording() async throws {
        let error = AudioCaptureError.deviceNotFound("USB Microphone")
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1)], streamError: error)
        let writer = InMemoryNoteWriter()
        // No other microphone to switch to.
        let coordinator = makeCoordinator(devices: [Fixtures.builtInMic], capture: capture, writer: writer)
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
        let coordinator = makeCoordinator(devices: [Fixtures.builtInMic], capture: capture, writer: writer)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { !coordinator.isRecording }

        #expect(coordinator.phase == .failed(message: error.localizedDescription))
        #expect(await writer.notes.isEmpty)
    }

    // MARK: - Summary

    /// Records a second of audio that `MockEngine` turns into `transcript`, and returns the note.
    private func recordNote(
        transcript: Transcript = Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "Hello.")]),
        summarizer: MockSummarizer?,
        isCall: Bool = false,
        automatically: Bool = false,
        configure: (RecordingCoordinator) -> Void = { _ in },
        whileRecording: (RecordingCoordinator) -> Void = { _ in }
    ) async throws -> (RecordingCoordinator, Note) {
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            engine: MockEngine(transcript: transcript),
            writer: writer,
            summarizer: summarizer
        )
        configure(coordinator)
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        if isCall { coordinator.markRecordingAsCall(automatically: automatically) }
        whileRecording(coordinator)
        await coordinator.stopRecording()
        return (coordinator, try #require(await writer.notes.first))
    }

    @Test func summarizesTranscriptIntoNote() async throws {
        let summary = NoteSummary(overview: "A greeting.", keyPoints: ["Someone said hello."])
        let summarizer = MockSummarizer(summary: summary)

        let (coordinator, note) = try await recordNote(summarizer: summarizer)

        #expect(coordinator.phase == .idle)
        #expect(note.summary == summary)
        #expect(summarizer.receivedTranscripts == [note.transcript])
        #expect(summarizer.receivedTemplates == [.general])
    }

    @Test func summaryTemplateDependsOnHowRecordingStarted() async throws {
        let setTemplates = { (coordinator: RecordingCoordinator) in
            coordinator.summaryTemplate = .standup
            coordinator.callSummaryTemplate = .clientCall
        }

        let manual = MockSummarizer()
        _ = try await recordNote(summarizer: manual, configure: setTemplates)
        #expect(manual.receivedTemplates == [.standup])

        let call = MockSummarizer()
        var preselected: SummaryTemplate?
        _ = try await recordNote(
            summarizer: call,
            isCall: true,
            configure: setTemplates,
            whileRecording: { preselected = $0.recordingSummaryTemplate }
        )
        // Shown as the recording's template once it's marked as a call.
        #expect(preselected == .clientCall)
        #expect(call.receivedTemplates == [.clientCall])
    }

    @Test func recordingSummaryTemplateCanBeChosenWhileRecording() async throws {
        let summarizer = MockSummarizer()
        var seen: [SummaryTemplate?] = []
        let (coordinator, _) = try await recordNote(
            summarizer: summarizer,
            configure: { coordinator in
                coordinator.callSummaryTemplate = .clientCall
                // Ignored outside a recording.
                coordinator.chooseSummaryTemplate(.standup)
                seen.append(coordinator.recordingSummaryTemplate)
            },
            whileRecording: { coordinator in
                seen.append(coordinator.recordingSummaryTemplate)
                coordinator.chooseSummaryTemplate(.oneOnOne)
                // A call detected after the user chose keeps their choice.
                coordinator.markRecordingAsCall()
                seen.append(coordinator.recordingSummaryTemplate)
            }
        )

        #expect(seen == [nil, .general, .oneOnOne])
        #expect(summarizer.receivedTemplates == [.oneOnOne])
        #expect(coordinator.recordingSummaryTemplate == nil)
    }

    @Test func noteIsSavedWithoutSummaryWhenSummarizingFails() async throws {
        let summarizer = MockSummarizer(error: SummarizationError.failed("guardrail"))

        let (coordinator, note) = try await recordNote(summarizer: summarizer)

        #expect(coordinator.phase == .idle)
        #expect(coordinator.lastNoteURL != nil)
        #expect(note.summary == nil)
        #expect(summarizer.receivedTranscripts.count == 1)
    }

    @Test func unavailableSummarizerIsSkipped() async throws {
        let summarizer = MockSummarizer(availability: .unavailable(reason: "Turn it on."))

        let (coordinator, note) = try await recordNote(summarizer: summarizer)

        #expect(coordinator.phase == .idle)
        #expect(note.summary == nil)
        #expect(summarizer.receivedTranscripts.isEmpty)
    }

    @Test func emptyTranscriptOrSummaryLeavesNoSummary() async throws {
        let silent = MockSummarizer()
        let (_, silentNote) = try await recordNote(transcript: Transcript(segments: []), summarizer: silent)
        #expect(silentNote.summary == nil)
        #expect(silent.receivedTranscripts.isEmpty)

        let empty = MockSummarizer(summary: NoteSummary(overview: " ", keyPoints: [""]))
        let (_, emptyNote) = try await recordNote(summarizer: empty)
        #expect(emptyNote.summary == nil)
        #expect(empty.receivedTranscripts.count == 1)
    }

    @Test func noteIsNamedAfterSummaryTitle() async throws {
        let summary = NoteSummary(title: "Release timeline", overview: "The release moves.")

        let (_, note) = try await recordNote(summarizer: MockSummarizer(summary: summary))
        #expect(note.title == "Release timeline")

        let (_, call) = try await recordNote(summarizer: MockSummarizer(summary: summary), isCall: true)
        #expect(call.title == "Call about Release timeline")

        var german = summary
        german.language = "de"
        let (_, germanCall) = try await recordNote(summarizer: MockSummarizer(summary: german), isCall: true)
        #expect(germanCall.title == "Anruf zu Release timeline")
    }

    @Test func notesSayHowTheRecordingWasStarted() async throws {
        let (_, manual) = try await recordNote(summarizer: nil)
        #expect(manual.trigger == .manual)

        let (_, prompted) = try await recordNote(summarizer: nil, isCall: true)
        #expect(prompted.trigger == .manual)

        let (_, automatic) = try await recordNote(summarizer: nil, isCall: true, automatically: true)
        #expect(automatic.trigger == .automatic)
    }

    @Test func markingAsCallOutsideARecordingIsIgnored() async throws {
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            engine: MockEngine(transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "Hi.")])),
            writer: writer,
            summarizer: MockSummarizer(summary: NoteSummary(title: "Hello"))
        )
        await coordinator.monitorDevices()
        coordinator.markRecordingAsCall()
        await coordinator.startRecording()
        await coordinator.stopRecording()

        #expect(try #require(await writer.notes.first).title == "Hello")
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

    // MARK: - Echo cancellation

    /// Records `EchoFixtures.systemAudio` and a microphone that hears it, with echo cancellation
    /// on or off, and returns the samples each track was transcribed from.
    private func recordEcho(cancelsEcho: Bool, echoCancellation: SubtractingEchoCancellation) async throws -> [[Float]]
    {
        let microphone = MockCapture()
        let systemAudio = MockCapture()
        let engine = MockEngine()
        let coordinator = makeCoordinator(
            captures: [Fixtures.builtInMic.id: microphone, AudioInputDevice.systemAudioID: systemAudio],
            engine: engine,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID],
            echoCancellation: echoCancellation
        )
        coordinator.cancelsEcho = cancelsEcho
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        systemAudio.yield(AudioChunk(samples: EchoFixtures.systemAudio, hostTime: 100))
        // Its level comes from the consumer once the audio is in the reference.
        try await waitUntil { coordinator.inputLevels[AudioInputDevice.systemAudioID] != nil }
        let pieces = EchoFixtures.pieces(of: EchoFixtures.microphone(voice: 0.25), size: 160)
        for (index, piece) in pieces.enumerated() {
            microphone.yield(AudioChunk(samples: piece, hostTime: 100 + Double(index * 160) / AudioChunk.sampleRate))
        }
        await coordinator.stopRecording()
        return await engine.receivedSamples
    }

    @Test func removesTheSystemAudioEchoFromTheMicrophone() async throws {
        let echoCancellation = SubtractingEchoCancellation()

        let tracks = try await recordEcho(cancelsEcho: true, echoCancellation: echoCancellation)

        #expect(echoCancellation.prepareCount == 1)
        #expect(tracks.map(\.count) == [16_000, 16_000])
        #expect(tracks.contains { $0 == EchoFixtures.systemAudio })
        #expect(tracks.contains { track in track.allSatisfy { abs($0 - 0.25) < 0.0001 } })
    }

    @Test func leavesTheMicrophoneAsItIsWithoutEchoCancellation() async throws {
        let echoCancellation = SubtractingEchoCancellation()

        let tracks = try await recordEcho(cancelsEcho: false, echoCancellation: echoCancellation)

        #expect(echoCancellation.prepareCount == 0)
        #expect(tracks.contains { $0 == EchoFixtures.systemAudio })
        #expect(tracks.contains { $0 == EchoFixtures.microphone(voice: 0.25) })
    }

    @Test func reportsTranscriptionProgress() async throws {
        let gate = Gate()
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            engine: MockEngine(progressBySampleCount: [16_000: 0.4], transcriptionGate: gate),
            writer: writer
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        let stopping = Task { await coordinator.stopRecording() }
        try await waitUntil { coordinator.phase == .transcribing(progress: 0.4) }
        await gate.open()
        await stopping.value

        #expect(coordinator.phase == .idle)
        #expect(coordinator.timeRemaining == nil)
        #expect(await writer.notes.count == 1)
    }

    @Test func weighsSourceProgressByLength() async throws {
        let gate = Gate()
        let microphone = MockCapture(chunks: [Fixtures.chunk(seconds: 3, hostTime: 100)])
        let systemAudio = MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)])
        let coordinator = makeCoordinator(
            captures: [Fixtures.builtInMic.id: microphone, AudioInputDevice.systemAudioID: systemAudio],
            // The short source is done, the long one hasn't started.
            engine: MockEngine(progressBySampleCount: [48_000: 0, 16_000: 1], transcriptionGate: gate),
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        let stopping = Task { await coordinator.stopRecording() }
        try await waitUntil { coordinator.phase == .transcribing(progress: 0.25) }
        await gate.open()
        await stopping.value

        #expect(coordinator.phase == .idle)
    }

    @Test func timeLeftFollowsTheSourcesStillTranscribing() async throws {
        let gate = Gate()
        let clock = LockedValue(Fixtures.startDate)
        let microphone = MockCapture(chunks: [Fixtures.chunk(seconds: 3, hostTime: 100)])
        let systemAudio = MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)])
        // System audio without speech is done at once, without reporting progress, which counts
        // it as done; the microphone takes its time.
        let engine = MockEngine(transcriptionGate: gate, ungatedSampleCounts: [16_000])
        let coordinator = makeCoordinator(
            captures: [Fixtures.builtInMic.id: microphone, AudioInputDevice.systemAudioID: systemAudio],
            engine: engine,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID],
            now: { clock.current }
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        let stopping = Task { await coordinator.stopRecording() }
        try await waitUntil { coordinator.phase == .transcribing(progress: 0.25) }
        var reportMicrophone = await engine.progressCallbacks[48_000]
        while reportMicrophone == nil {
            try await Task.sleep(for: .milliseconds(5))
            reportMicrophone = await engine.progressCallbacks[48_000]
        }
        clock.update { $0 += 10 }
        reportMicrophone?(0.5)
        try await waitUntil { coordinator.phase == .transcribing(progress: 0.625) }

        // Half the microphone took 10 s, so the rest takes another 10 s. Counting the system
        // audio's share as done in those 10 s as well would make it 6 s.
        let remaining = try #require(coordinator.timeRemaining)
        #expect(abs(remaining - 10) < 0.001)

        await gate.open()
        await stopping.value
        #expect(coordinator.phase == .idle)
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

    @Test func sourceFailingToTranscribeKeepsTheOthers() async throws {
        let error = TranscriptionError.failed("boom")
        let microphone = MockCapture(chunks: [Fixtures.chunk(seconds: 2, hostTime: 100)])
        let systemAudio = MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)])
        let engine = MockEngine(
            transcriptsBySampleCount: [
                32_000: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "Hello there.")])
            ],
            transcribeErrorsBySampleCount: [16_000: error]
        )
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [Fixtures.builtInMic.id: microphone, AudioInputDevice.systemAudioID: systemAudio],
            engine: engine,
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        await coordinator.stopRecording()

        let note = try #require(await writer.notes.first)
        #expect(note.sources == [Fixtures.builtInMic, .systemAudio])
        #expect(
            note.transcript
                == Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "Hello there.", speaker: "Me")])
        )
        #expect(coordinator.lastNoteURL != nil)
        #expect(
            coordinator.phase
                == .failed(message: RecordingCoordinator.untranscribedMessage(for: [.systemAudio], error: error))
        )
        #expect(coordinator.modelError == nil)
    }

    @Test func sourceFailingToTranscribeAfterAnInterruptionReportsBoth() async throws {
        let captureError = AudioCaptureError.microphonePermissionDenied
        let transcriptionError = TranscriptionError.failed("boom")
        let microphone = MockCapture(chunks: [Fixtures.chunk(seconds: 2, hostTime: 100)], streamError: captureError)
        let systemAudio = MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [Fixtures.builtInMic.id: microphone, AudioInputDevice.systemAudioID: systemAudio],
            engine: MockEngine(
                transcriptsBySampleCount: [
                    32_000: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "Hello there.")])
                ],
                transcribeErrorsBySampleCount: [16_000: transcriptionError]
            ),
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        try await waitUntil { coordinator.lastNoteURL != nil }

        #expect(await writer.notes.count == 1)
        #expect(
            coordinator.phase
                == .failed(
                    message: RecordingCoordinator.interruptedMessage(for: captureError) + " "
                        + RecordingCoordinator.untranscribedMessage(for: [.systemAudio], error: transcriptionError)
                )
        )
    }

    /// With no speech from the sources that worked, if any, the note would only be empty.
    @Test(arguments: [true, false])
    func failedSourceWithoutSpeechFromTheOthersSavesNoNote(everySourceFails: Bool) async {
        let error = TranscriptionError.failed("boom")
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [
                Fixtures.builtInMic.id: MockCapture(chunks: [Fixtures.chunk(seconds: 2, hostTime: 100)]),
                AudioInputDevice.systemAudioID: MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)]),
            ],
            // Otherwise the microphone is transcribed, but without speech.
            engine: everySourceFails
                ? MockEngine(transcribeError: error) : MockEngine(transcribeErrorsBySampleCount: [16_000: error]),
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        await coordinator.stopRecording()

        #expect(coordinator.phase == .failed(message: error.localizedDescription))
        #expect(coordinator.lastNoteURL == nil)
        #expect(await writer.notes.isEmpty)
    }

    @Test func cancelledTranscriptionIsNoFailedSource() async throws {
        let gate = Gate()
        let engine = MockEngine(
            transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "Hello there.")]),
            transcriptionGate: gate,
            ungatedSampleCounts: [32_000]
        )
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [
                Fixtures.builtInMic.id: MockCapture(chunks: [Fixtures.chunk(seconds: 2, hostTime: 100)]),
                AudioInputDevice.systemAudioID: MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)]),
            ],
            engine: engine,
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        let stopping = Task { await coordinator.stopRecording() }
        while await engine.receivedSampleCounts.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        stopping.cancel()
        await gate.open()
        await stopping.value

        // Not a note of the microphone that says system audio couldn't be transcribed.
        #expect(coordinator.phase == .idle)
        #expect(await writer.notes.isEmpty)
    }

    // MARK: - Pausing

    @Test func pauseStopsTheInputsAndResumeStartsThemAgain() async throws {
        // A minute passes while paused, by the host clock.
        let clock = LockedValue<TimeInterval>(101)
        let first = MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)])
        let second = MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 161)])
        let engine = MockEngine()
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            queuedCaptures: [Fixtures.builtInMic.id: [first, second]],
            engine: engine,
            writer: writer,
            hostClock: { clock.current }
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        #expect(!coordinator.isPaused)

        await coordinator.pauseRecording()
        #expect(coordinator.phase == .paused(recorded: 0))
        #expect(coordinator.isPaused)
        #expect(coordinator.isRecording)
        #expect(coordinator.canStopRecording)
        #expect(first.stopCount == 1)
        #expect(coordinator.inputLevels.isEmpty)
        #expect(coordinator.recordingStartedAt == Fixtures.startDate)

        clock.update { $0 = 161 }
        await coordinator.resumeRecording()
        #expect(coordinator.phase == .recording(startedAt: Fixtures.startDate))
        #expect(!coordinator.isPaused)
        #expect(second.startCount == 1)

        await coordinator.stopRecording()
        #expect(coordinator.phase == .idle)
        #expect(second.stopCount == 1)
        #expect(coordinator.recordingStartedAt == nil)
        // The minute paused isn't filled with silence.
        #expect(await engine.receivedSampleCounts == [32_000])
        let note = try #require(await writer.notes.first)
        #expect(note.duration == 2)
        #expect(note.sources == [Fixtures.builtInMic])
        #expect(engine.recordingsInProgress.current == 0)
    }

    // MARK: - Moments

    @Test func addedMomentsGoIntoTheNote() async throws {
        let date = LockedValue(Fixtures.startDate)
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 10)]),
            writer: writer,
            now: { date.current }
        )
        await coordinator.monitorDevices()
        #expect(coordinator.momentTime == nil)
        #expect(coordinator.addMoment(at: 0) == nil)
        await coordinator.startRecording()

        date.update { $0 = Fixtures.startDate.addingTimeInterval(3) }
        let time = try #require(coordinator.momentTime)
        #expect(time == 3)
        // Marked at 3 s, added once the note on it is written.
        date.update { $0 = Fixtures.startDate.addingTimeInterval(8) }
        let first = try #require(coordinator.addMoment(at: time, text: "  Budget approved \n"))
        // Past the end of the audio.
        let second = try #require(coordinator.addMoment(at: 12))
        #expect(coordinator.moments.map(\.id) == [first.id, second.id])
        await coordinator.stopRecording()

        let note = try #require(await writer.notes.first)
        #expect(
            note.moments == [Moment(id: first.id, time: 3, text: "Budget approved"), Moment(id: second.id, time: 10)]
        )
        #expect(coordinator.moments.isEmpty)
        // Too late for that note.
        #expect(coordinator.addMoment(at: 5) == nil)
        #expect(coordinator.moments.isEmpty)
    }

    @Test func momentWhilePausedIsMarkedWhereItPaused() async throws {
        let date = LockedValue(Fixtures.startDate)
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            now: { date.current }
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        date.update { $0 = Fixtures.startDate.addingTimeInterval(5) }
        await coordinator.pauseRecording()
        date.update { $0 = Fixtures.startDate.addingTimeInterval(65) }
        #expect(coordinator.momentTime == 5)
        await coordinator.resumeRecording()
        date.update { $0 = Fixtures.startDate.addingTimeInterval(67) }
        #expect(coordinator.momentTime == 7)
    }

    @Test func pausedTimeIsLeftOutOfTheRecordedTime() async {
        let date = LockedValue(Fixtures.startDate)
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            now: { date.current }
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        date.update { $0 = Fixtures.startDate.addingTimeInterval(5) }
        await coordinator.pauseRecording()
        #expect(coordinator.phase == .paused(recorded: 5))

        date.update { $0 = Fixtures.startDate.addingTimeInterval(65) }
        await coordinator.resumeRecording()
        #expect(coordinator.phase == .recording(startedAt: Fixtures.startDate.addingTimeInterval(60)))
        #expect(coordinator.recordingStartedAt == Fixtures.startDate)
    }

    @Test func pausingKeepsInputsLinedUp() async throws {
        // System audio starts a second after the microphone; both pause at 102 and resume at 200.
        let clock = LockedValue<TimeInterval>(102)
        let microphone = [
            MockCapture(chunks: [Fixtures.chunk(seconds: 2, hostTime: 100)]),
            MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 200)]),
        ]
        let systemAudio = [
            MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 101)]),
            MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 200)]),
        ]
        let engine = MockEngine(transcriptsBySampleCount: [
            48_000: Transcript(segments: [TranscriptSegment(start: 2.5, end: 3, text: "After the break.")]),
            32_000: Transcript(segments: [TranscriptSegment(start: 1, end: 1.5, text: "Welcome back.")]),
        ])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            queuedCaptures: [Fixtures.builtInMic.id: microphone, AudioInputDevice.systemAudioID: systemAudio],
            engine: engine,
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID],
            hostClock: { clock.current }
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        await coordinator.pauseRecording()
        clock.update { $0 = 200 }
        await coordinator.resumeRecording()
        await coordinator.stopRecording()

        #expect(await engine.receivedSampleCounts.sorted() == [32_000, 48_000])
        let note = try #require(await writer.notes.first)
        #expect(note.duration == 3)
        #expect(
            note.transcript.segments == [
                TranscriptSegment(start: 2, end: 2.5, text: "Welcome back.", speaker: "Others"),
                TranscriptSegment(start: 2.5, end: 3, text: "After the break.", speaker: "Me"),
            ]
        )
    }

    @Test func stopWhilePausedSavesTheNote() async throws {
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1)])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(capture: capture, writer: writer)
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        await coordinator.pauseRecording()

        await coordinator.toggleRecording()
        #expect(coordinator.phase == .idle)
        #expect(capture.stopCount == 1)
        #expect(try #require(await writer.notes.first).duration == 1)
    }

    @Test func inputsChosenWhilePausedRecordOnResume() async throws {
        let builtIn = MockCapture(chunks: [Fixtures.chunk(seconds: 1)])
        let usb = MockCapture(chunks: [Fixtures.chunk(seconds: 1)])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [Fixtures.builtInMic.id: builtIn, Fixtures.usbMic.id: usb],
            writer: writer
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        await coordinator.pauseRecording()

        #expect(coordinator.selectDevices([Fixtures.usbMic]))
        #expect(coordinator.selectedDevices == [Fixtures.usbMic])
        try await Task.sleep(for: .milliseconds(20))
        #expect(usb.startCount == 0)
        #expect(coordinator.isPaused)

        await coordinator.resumeRecording()
        #expect(usb.startCount == 1)
        #expect(builtIn.startCount == 1)
        await coordinator.stopRecording()
        #expect(try #require(await writer.notes.first).sources == [Fixtures.builtInMic, Fixtures.usbMic])
    }

    @Test func deviceChangesWhilePausedStartNothing() async throws {
        let provider = LiveDeviceProvider(devices: Fixtures.devices)
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1)])
        let coordinator = makeCoordinator(deviceProvider: provider, capture: capture)
        let monitor = Task { await coordinator.monitorDevices() }
        defer { monitor.cancel() }
        try await waitUntil { !coordinator.devices.isEmpty }
        await coordinator.startRecording()
        await coordinator.pauseRecording()

        // The USB microphone becomes the default, which the recording follows once resumed.
        provider.send([Fixtures.usbMicAsDefault, Fixtures.builtInMicNotDefault, .systemAudio])
        try await waitUntil { coordinator.selectedDevices == [Fixtures.usbMicAsDefault] }
        try await Task.sleep(for: .milliseconds(20))
        #expect(capture.startCount == 1)
        #expect(coordinator.isPaused)
    }

    @Test func noInputStartingOnResumeEndsTheRecording() async throws {
        let error = AudioCaptureError.deviceUnavailable("Couldn't start “MacBook Pro Microphone”")
        let writer = InMemoryNoteWriter()
        // No other microphone to fall back to.
        let coordinator = makeCoordinator(
            devices: [Fixtures.builtInMic, .systemAudio],
            queuedCaptures: [
                Fixtures.builtInMic.id: [
                    MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
                    MockCapture(startError: error),
                ]
            ],
            writer: writer
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        await coordinator.pauseRecording()
        await coordinator.resumeRecording()

        try await waitUntil { !coordinator.isRecording }
        #expect(coordinator.phase == .failed(message: RecordingCoordinator.interruptedMessage(for: error)))
        #expect(try #require(await writer.notes.first).duration == 1)
    }

    @Test func pauseAndResumeAreIgnoredOutsideTheirPhase() async {
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1)])
        let coordinator = makeCoordinator(capture: capture)
        await coordinator.monitorDevices()

        await coordinator.pauseRecording()
        #expect(coordinator.phase == .idle)

        await coordinator.startRecording()
        await coordinator.resumeRecording()
        #expect(coordinator.phase == .recording(startedAt: Fixtures.startDate))
        #expect(capture.startCount == 1)

        await coordinator.togglePause()
        await coordinator.pauseRecording()
        #expect(coordinator.isPaused)
        #expect(capture.stopCount == 1)
    }

    @Test func liveTextCarriesOnAfterAPause() async throws {
        let clock = LockedValue<TimeInterval>(101)
        let live = MockLiveSession(updatesBySampleCount: [
            16_000: LiveTranscriptUpdate(words: [LiveWord(text: "Before.", start: 0.25, end: 0.75)]),
            8_000: LiveTranscriptUpdate(words: [LiveWord(text: "After.", start: 0.25, end: 0.5)]),
        ])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            queuedCaptures: [
                Fixtures.builtInMic.id: [
                    MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)]),
                    MockCapture(chunks: [Fixtures.chunk(seconds: 0.5, hostTime: 300)]),
                ]
            ],
            engine: MockEngine(liveSession: live),
            writer: writer,
            hostClock: { clock.current }
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        try await waitUntil { coordinator.liveTranscript.lines.count == 1 }
        await coordinator.pauseRecording()
        clock.update { $0 = 300 }
        await coordinator.resumeRecording()
        // Half a second after the words before the pause, so on the same line.
        try await waitUntil { coordinator.liveTranscript.lines.map(\.text) == ["Before. After."] }
        await coordinator.stopRecording()

        let note = try #require(await writer.notes.first)
        #expect(
            note.transcript.segments == [
                TranscriptSegment(start: 0.25, end: 0.75, text: "Before."),
                TranscriptSegment(start: 1.25, end: 1.5, text: "After."),
            ]
        )
        #expect(note.duration == 1.5)
    }

    // MARK: - Switching inputs

    @Test func switchesToDefaultMicrophoneWhenDeviceGoesAway() async throws {
        let error = AudioCaptureError.deviceNotFound("USB Microphone")
        let usb = MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)], streamError: error)
        let builtIn = MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 102)])
        let engine = MockEngine()
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [Fixtures.usbMic.id: usb, Fixtures.builtInMic.id: builtIn],
            engine: engine,
            writer: writer,
            preferredDeviceIDs: [Fixtures.usbMic.id]
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.inputLevels[Fixtures.builtInMic.id] != nil }
        #expect(coordinator.isRecording)
        #expect(coordinator.selectedDevices == [Fixtures.builtInMic])
        #expect(coordinator.inputLevels[Fixtures.usbMic.id] == nil)
        #expect(usb.stopCount == 1)

        await coordinator.stopRecording()

        #expect(coordinator.phase == .idle)
        #expect(builtIn.stopCount == 1)
        // One track, with the second it took to switch left silent.
        #expect(await engine.receivedSampleCounts == [48_000])
        let note = try #require(await writer.notes.first)
        #expect(note.sources == [Fixtures.usbMic, Fixtures.builtInMic])
        #expect(note.duration == 3)
    }

    @Test func switchesWhenDeviceLeavesTheListAndBackWhenItReturns() async throws {
        let provider = LiveDeviceProvider(devices: [Fixtures.usbMic, Fixtures.builtInMic])
        let firstUSB = MockCapture()
        let builtIn = MockCapture()
        let secondUSB = MockCapture()
        let coordinator = makeCoordinator(
            deviceProvider: provider,
            captures: [Fixtures.builtInMic.id: builtIn],
            queuedCaptures: [Fixtures.usbMic.id: [firstUSB, secondUSB]],
            preferredDeviceIDs: [Fixtures.usbMic.id]
        )
        let monitor = Task { await coordinator.monitorDevices() }
        defer { monitor.cancel() }
        try await waitUntil { coordinator.selectedDevices == [Fixtures.usbMic] }

        await coordinator.startRecording()
        provider.send([Fixtures.builtInMic])
        try await waitUntil { firstUSB.stopCount == 1 }
        #expect(coordinator.selectedDevices == [Fixtures.builtInMic])

        provider.send([Fixtures.builtInMic, Fixtures.usbMic])
        try await waitUntil { builtIn.stopCount == 1 }
        #expect(coordinator.selectedDevices == [Fixtures.usbMic])
        #expect(coordinator.isRecording)
        try await waitUntil { secondUSB.startCount == 1 }

        await coordinator.stopRecording()
        // Stopped by the switch itself if it was still starting when the recording ended.
        try await waitUntil { secondUSB.stopCount == 1 }
        // The mocks record nothing.
        #expect(coordinator.phase == .failed(message: RecordingCoordinator.tooShortMessage))
    }

    @Test func followsNewDefaultMicrophoneWhileRecording() async throws {
        let provider = LiveDeviceProvider(devices: [Fixtures.usbMic, Fixtures.builtInMic])
        let usb = MockCapture()
        let builtIn = MockCapture()
        let coordinator = makeCoordinator(
            deviceProvider: provider,
            captures: [Fixtures.builtInMic.id: builtIn, Fixtures.usbMic.id: usb],
            preferredDeviceIDs: [AudioInputDevice.defaultMicrophoneID]
        )
        let monitor = Task { await coordinator.monitorDevices() }
        defer { monitor.cancel() }
        try await waitUntil { coordinator.selectedDevices == [Fixtures.builtInMic] }

        await coordinator.startRecording()
        // Connecting AirPods makes them the default input.
        provider.send([Fixtures.usbMicAsDefault, Fixtures.builtInMicNotDefault])
        try await waitUntil { builtIn.stopCount == 1 }
        #expect(coordinator.selectedDevices == [Fixtures.usbMicAsDefault])
        #expect(coordinator.isRecording)
        try await waitUntil { usb.startCount == 1 }

        await coordinator.stopRecording()
        // Stopped by the switch itself if it was still starting when the recording ended.
        try await waitUntil { usb.stopCount == 1 }
    }

    @Test func keepsOtherInputsWhenNoMicrophoneIsLeft() async throws {
        let error = AudioCaptureError.deviceNotFound("USB Microphone")
        let usb = MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)], streamError: error)
        let systemAudio = MockCapture(chunks: [Fixtures.chunk(seconds: 2, hostTime: 100)])
        let engine = MockEngine()
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            devices: [Fixtures.usbMic, .systemAudio],
            captures: [Fixtures.usbMic.id: usb, AudioInputDevice.systemAudioID: systemAudio],
            engine: engine,
            writer: writer,
            preferredDeviceIDs: [Fixtures.usbMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.selectedDevices == [.systemAudio] }
        #expect(coordinator.isRecording)

        await coordinator.stopRecording()
        #expect(coordinator.phase == .idle)
        #expect(await engine.receivedSampleCounts.sorted() == [16_000, 32_000])
        #expect(await writer.notes.first?.sources == [Fixtures.usbMic, .systemAudio])
    }

    @Test func otherCaptureErrorsStillEndTheRecording() async throws {
        let error = AudioCaptureError.microphonePermissionDenied
        let usb = MockCapture(chunks: [Fixtures.chunk(seconds: 1)], streamError: error)
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [Fixtures.usbMic.id: usb],
            writer: writer,
            preferredDeviceIDs: [Fixtures.usbMic.id]
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.lastNoteURL != nil }

        #expect(coordinator.phase == .failed(message: RecordingCoordinator.interruptedMessage(for: error)))
        #expect(await writer.notes.first?.sources == [Fixtures.usbMic])
    }

    @Test func userSwitchesMicrophoneWhileRecording() async throws {
        let builtIn = MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)])
        let usb = MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 101)])
        let transcript = Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "Hello.")])
        let engine = MockEngine(transcript: transcript)
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [Fixtures.builtInMic.id: builtIn, Fixtures.usbMic.id: usb],
            engine: engine,
            writer: writer
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        #expect(coordinator.selectDevices([Fixtures.usbMic]))
        #expect(coordinator.selectedDevices == [Fixtures.usbMic])
        try await waitUntil { coordinator.inputLevels[Fixtures.usbMic.id] != nil }
        #expect(builtIn.stopCount == 1)

        await coordinator.stopRecording()
        #expect(usb.stopCount == 1)
        #expect(await engine.receivedSampleCounts == [32_000])
        let note = try #require(await writer.notes.first)
        #expect(note.sources == [Fixtures.builtInMic, Fixtures.usbMic])
        // Still one input, so no speaker labels.
        #expect(note.transcript == transcript)
    }

    @Test func userTurnsSystemAudioOnAndOffWhileRecording() async throws {
        let microphone = MockCapture(chunks: [Fixtures.chunk(seconds: 3, hostTime: 100)])
        let systemAudio = MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 101)])
        let engine = MockEngine()
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [Fixtures.builtInMic.id: microphone, AudioInputDevice.systemAudioID: systemAudio],
            engine: engine,
            writer: writer
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        coordinator.selectDevices([Fixtures.builtInMic, .systemAudio])
        try await waitUntil { coordinator.inputLevels[AudioInputDevice.systemAudioID] != nil }
        coordinator.selectDevices([Fixtures.builtInMic])
        try await waitUntil { systemAudio.stopCount == 1 }
        #expect(coordinator.isRecording)
        #expect(microphone.stopCount == 0)

        await coordinator.stopRecording()
        #expect(await engine.receivedSampleCounts.sorted() == [16_000, 48_000])
        let note = try #require(await writer.notes.first)
        #expect(note.sources == [Fixtures.builtInMic, .systemAudio])
        #expect(note.duration == 3)
    }

    @Test func failedSwitchFallsBackToDefaultMicrophone() async throws {
        let error = AudioCaptureError.deviceUnavailable("Couldn't start “USB Microphone”")
        let first = MockCapture()
        let second = MockCapture()
        let coordinator = makeCoordinator(
            captures: [Fixtures.usbMic.id: MockCapture(startError: error)],
            queuedCaptures: [Fixtures.builtInMic.id: [first, second]]
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        coordinator.selectDevices([Fixtures.usbMic])
        try await waitUntil { coordinator.selectedDevices == [Fixtures.builtInMic] }
        try await waitUntil { first.stopCount == 1 }
        #expect(coordinator.isRecording)
        try await waitUntil { second.startCount == 1 }

        await coordinator.stopRecording()
        // Stopped by the switch itself if it was still starting when the recording ended.
        try await waitUntil { second.stopCount == 1 }
        // The mocks record nothing.
        #expect(coordinator.phase == .failed(message: RecordingCoordinator.tooShortMessage))
    }

    @Test func choosingSystemDefaultRetriesTheDefaultMicrophone() async throws {
        let error = AudioCaptureError.deviceNotFound("MacBook Pro Microphone")
        let failedBuiltIn = MockCapture(streamError: error)
        let builtIn = MockCapture(chunks: [Fixtures.chunk(seconds: 1)])
        let usb = MockCapture()
        let coordinator = makeCoordinator(
            captures: [Fixtures.usbMic.id: usb],
            queuedCaptures: [Fixtures.builtInMic.id: [failedBuiltIn, builtIn]],
            preferredDeviceIDs: [AudioInputDevice.defaultMicrophoneID]
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        try await waitUntil { usb.startCount == 1 }
        #expect(coordinator.selectedDevices == [Fixtures.usbMic])

        #expect(coordinator.selectDevices([.defaultMicrophone]))
        #expect(coordinator.selectedDevices == [Fixtures.builtInMic])
        try await waitUntil { coordinator.inputLevels[Fixtures.builtInMic.id] != nil }
        #expect(usb.stopCount == 1)
        #expect(coordinator.isRecording)

        await coordinator.stopRecording()
        #expect(builtIn.stopCount == 1)
    }

    @Test func restartsCapturesWhenTheAudioServiceRestarts() async throws {
        let interrupted = MockCapture(
            chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)],
            streamError: AudioCaptureError.audioServiceRestarted
        )
        let restarted = MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 102)])
        let engine = MockEngine()
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            queuedCaptures: [Fixtures.builtInMic.id: [interrupted, restarted]],
            engine: engine,
            writer: writer
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        try await waitUntil { restarted.startCount == 1 }
        // Its level shows once it's recording into the session.
        try await waitUntil { coordinator.inputLevels[Fixtures.builtInMic.id] != nil }
        #expect(coordinator.isRecording)
        #expect(coordinator.selectedDevices == [Fixtures.builtInMic])

        await coordinator.stopRecording()
        #expect(coordinator.phase == .idle)
        #expect(restarted.stopCount == 1)
        // One track, with the second it took to restart left silent.
        #expect(await engine.receivedSampleCounts == [48_000])
        #expect(await writer.notes.first?.sources == [Fixtures.builtInMic])
    }

    @Test func reusedMicrophoneLaneNamesEachPartByItsDevice() async throws {
        let other = AudioInputDevice(id: "other", name: "Other Microphone", kind: .microphone)
        // Both microphone lanes come out 3 s long: the built-in microphone's second, a second
        // switching, and the other microphone's second.
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0.2, end: 0.8, text: "Built-in."),
            TranscriptSegment(start: 2.2, end: 2.8, text: "Other."),
        ])
        let engine = MockEngine(transcriptsBySampleCount: [48_000: transcript])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            devices: [Fixtures.usbMic, Fixtures.builtInMic, other, .systemAudio],
            captures: [
                Fixtures.usbMic.id: MockCapture(chunks: [Fixtures.chunk(seconds: 4, hostTime: 100)]),
                Fixtures.builtInMic.id: MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)]),
                other.id: MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 102)]),
                AudioInputDevice.systemAudioID: MockCapture(chunks: [Fixtures.chunk(seconds: 2, hostTime: 100)]),
            ],
            engine: engine,
            writer: writer,
            preferredDeviceIDs: [Fixtures.usbMic.id, Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        // The other microphone takes over the built-in one's lane.
        coordinator.selectDevices([Fixtures.usbMic, other, .systemAudio])
        try await waitUntil { coordinator.inputLevels[other.id] != nil }
        await coordinator.stopRecording()

        #expect(await engine.receivedSampleCounts.sorted() == [32_000, 48_000, 64_000])
        let note = try #require(await writer.notes.first)
        #expect(note.transcript.speakers == ["Me (MacBook Pro Microphone)", "Me (Other Microphone)"])
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

    @Test func silentSystemAudioIsOnlyFlaggedWhileSomethingPlays() async throws {
        let microphone = MockCapture(chunks: [Fixtures.chunk(seconds: 1, amplitude: 0)])
        let systemAudio = MockCapture(chunks: [Fixtures.chunk(seconds: 1, amplitude: 0)])
        let playback = MockPlaybackMonitor()
        let coordinator = makeCoordinator(
            captures: [Fixtures.builtInMic.id: microphone, AudioInputDevice.systemAudioID: systemAudio],
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID],
            playbackMonitor: playback
        )
        coordinator.silenceWarningDelay = .milliseconds(50)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        // A muted microphone is flagged whether or not anything plays.
        try await waitUntil { coordinator.silentDevices == [Fixtures.builtInMic] }
        // Nothing plays, so silent system audio is no sign of a missing permission.
        try await Task.sleep(for: .milliseconds(200))
        #expect(coordinator.silentDevices == [Fixtures.builtInMic])

        playback.isPlaying.update { $0 = true }
        try await waitUntil { coordinator.silentDevices == [Fixtures.builtInMic, .systemAudio] }

        await coordinator.stopRecording()
    }

    @Test func sourceThatIsHeardLeavesSilentList() async throws {
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1, amplitude: 0)])
        let coordinator = makeCoordinator(capture: capture)
        coordinator.silenceWarningDelay = .milliseconds(50)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.silentDevices == [Fixtures.builtInMic] }

        capture.yield(Fixtures.chunk(seconds: 0.1))
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

    // MARK: - Live transcription

    @Test func liveTextBecomesTheNote() async throws {
        let live = MockLiveSession(
            updatesBySampleCount: [
                16_000: LiveTranscriptUpdate(words: [
                    LiveWord(text: "Hello", start: 0.1, end: 0.4),
                    LiveWord(text: "world.", start: 0.5, end: 0.9),
                ])
            ],
            // The end of the input, which the session held back until it finished.
            finishUpdate: LiveTranscriptUpdate(words: [LiveWord(text: "Bye.", start: 1, end: 1.2)])
        )
        let engine = MockEngine(liveSession: live)
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            engine: engine,
            writer: writer
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        #expect(coordinator.showsLiveTranscript)
        try await waitUntil { !coordinator.liveTranscript.isEmpty }
        #expect(coordinator.liveTranscript.lines.map(\.text) == ["Hello world."])
        // A single input isn't labeled.
        #expect(coordinator.liveTranscript.lines.map(\.speaker) == [nil])

        await coordinator.stopRecording()

        #expect(coordinator.phase == .idle)
        #expect(!coordinator.showsLiveTranscript)
        #expect(coordinator.liveTranscript.isEmpty)
        #expect(
            await writer.notes.first?.transcript.segments == [
                TranscriptSegment(start: 0.1, end: 1.2, text: "Hello world. Bye.")
            ]
        )
        #expect(await writer.notes.first?.duration == 1)
        #expect(await live.pushedSampleCounts == [16_000])
        #expect(await live.finishCount == 1)
        // Nothing is transcribed afterwards.
        #expect(await engine.receivedSampleCounts.isEmpty)
    }

    @Test func liveTextLabelsAndOrdersSources() async throws {
        // The system audio starts a second after the microphone, according to the host clock.
        // Times are exact in binary, whichever input's text arrives first.
        let live = MockLiveSession(updatesBySampleCount: [
            32_000: LiveTranscriptUpdate(words: [LiveWord(text: "Morning.", start: 0.25, end: 0.75)]),
            16_000: LiveTranscriptUpdate(words: [LiveWord(text: "Hi!", start: 0, end: 0.25)]),
        ])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [
                Fixtures.builtInMic.id: MockCapture(chunks: [Fixtures.chunk(seconds: 2, hostTime: 100)]),
                AudioInputDevice.systemAudioID: MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 101)]),
            ],
            engine: MockEngine(liveSession: live),
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.liveTranscript.lines.count == 2 }

        #expect(coordinator.liveTranscript.lines.map(\.speaker) == ["Me", "Others"])
        #expect(coordinator.liveTranscript.lines.map(\.text) == ["Morning.", "Hi!"])
        await coordinator.stopRecording()

        #expect(
            await writer.notes.first?.transcript.segments == [
                TranscriptSegment(start: 0.25, end: 0.75, text: "Morning.", speaker: "Me"),
                TranscriptSegment(start: 1, end: 1.25, text: "Hi!", speaker: "Others"),
            ]
        )
    }

    @Test func liveTextDropsEchoFromTheNote() async throws {
        // Without headphones the microphone also hears the call, a moment later.
        let live = MockLiveSession(updatesBySampleCount: [
            32_000: LiveTranscriptUpdate(words: [
                LiveWord(text: "See", start: 0.1, end: 0.3),
                LiveWord(text: "you", start: 0.35, end: 0.55),
                LiveWord(text: "next", start: 0.6, end: 0.8),
                LiveWord(text: "week.", start: 0.85, end: 1.05),
            ]),
            16_000: LiveTranscriptUpdate(words: [
                LiveWord(text: "See", start: 0, end: 0.2),
                LiveWord(text: "you", start: 0.25, end: 0.45),
                LiveWord(text: "next", start: 0.5, end: 0.7),
                LiveWord(text: "week.", start: 0.75, end: 0.95),
            ]),
        ])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [
                Fixtures.builtInMic.id: MockCapture(chunks: [Fixtures.chunk(seconds: 2, hostTime: 100)]),
                AudioInputDevice.systemAudioID: MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)]),
            ],
            engine: MockEngine(liveSession: live),
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.liveTranscript.lines.count >= 2 }
        await coordinator.stopRecording()

        // However the two inputs' lines interleaved on screen.
        #expect(
            await writer.notes.first?.transcript.segments == [
                TranscriptSegment(start: 0, end: 0.95, text: "See you next week.", speaker: "Others")
            ]
        )
    }

    @Test func liveTextFollowsADeviceSwitch() async throws {
        // The USB microphone goes away after a second; the built-in one takes over 3 s later.
        let error = AudioCaptureError.deviceNotFound("USB Microphone")
        let usb = MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)], streamError: error)
        let builtIn = MockCapture(chunks: [Fixtures.chunk(seconds: 0.5, hostTime: 104)])
        let live = MockLiveSession(updatesBySampleCount: [
            16_000: LiveTranscriptUpdate(words: [LiveWord(text: "Before.", start: 0.25, end: 0.75)]),
            8_000: LiveTranscriptUpdate(words: [LiveWord(text: "After.", start: 0.25, end: 0.5)]),
        ])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [Fixtures.usbMic.id: usb, Fixtures.builtInMic.id: builtIn],
            engine: MockEngine(liveSession: live),
            writer: writer,
            preferredDeviceIDs: [Fixtures.usbMic.id]
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.liveTranscript.lines.count == 2 }
        await coordinator.stopRecording()

        // Each device's session counts from its own start, and both stay one unlabeled input.
        #expect(await live.finishCount == 2)
        let note = try #require(await writer.notes.first)
        #expect(
            note.transcript.segments == [
                TranscriptSegment(start: 0.25, end: 0.75, text: "Before."),
                TranscriptSegment(start: 4.25, end: 4.5, text: "After."),
            ]
        )
        #expect(note.duration == 4.5)
    }

    @Test func liveTextLabelsSystemAudioTurnedOnMidRecording() async throws {
        let microphone = MockCapture(chunks: [Fixtures.chunk(seconds: 3, hostTime: 100)])
        let systemAudio = MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 101)])
        let live = MockLiveSession(updatesBySampleCount: [
            48_000: LiveTranscriptUpdate(words: [LiveWord(text: "Hello.", start: 0.25, end: 0.75)]),
            16_000: LiveTranscriptUpdate(words: [LiveWord(text: "Hi!", start: 0, end: 0.25)]),
        ])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [Fixtures.builtInMic.id: microphone, AudioInputDevice.systemAudioID: systemAudio],
            engine: MockEngine(liveSession: live),
            writer: writer
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { !coordinator.liveTranscript.isEmpty }
        // A single input isn't labeled, until there's a second.
        #expect(coordinator.liveTranscript.lines.map(\.speaker) == [nil])
        coordinator.selectDevices([Fixtures.builtInMic, .systemAudio])
        try await waitUntil { coordinator.liveTranscript.lines.count == 2 }
        #expect(coordinator.liveTranscript.lines.map(\.speaker) == ["Me", "Others"])

        await coordinator.stopRecording()
        #expect(
            await writer.notes.first?.transcript.segments == [
                TranscriptSegment(start: 0.25, end: 0.75, text: "Hello.", speaker: "Me"),
                TranscriptSegment(start: 1, end: 1.25, text: "Hi!", speaker: "Others"),
            ]
        )
    }

    @Test func liveTextNamesEachPartOfAReusedMicrophoneLaneByItsDevice() async throws {
        let other = AudioInputDevice(id: "other", name: "Other Microphone", kind: .microphone)
        // The built-in microphone's second, a second switching, and the other microphone's half.
        let live = MockLiveSession(updatesBySampleCount: [
            16_000: LiveTranscriptUpdate(words: [LiveWord(text: "Built-in.", start: 0.2, end: 0.8)]),
            8_000: LiveTranscriptUpdate(words: [LiveWord(text: "Other.", start: 0.2, end: 0.4)]),
        ])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            devices: [Fixtures.usbMic, Fixtures.builtInMic, other, .systemAudio],
            captures: [
                Fixtures.usbMic.id: MockCapture(chunks: [Fixtures.chunk(seconds: 4, hostTime: 100)]),
                Fixtures.builtInMic.id: MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)]),
                other.id: MockCapture(chunks: [Fixtures.chunk(seconds: 0.5, hostTime: 102)]),
                AudioInputDevice.systemAudioID: MockCapture(chunks: [Fixtures.chunk(seconds: 2, hostTime: 100)]),
            ],
            engine: MockEngine(liveSession: live),
            writer: writer,
            preferredDeviceIDs: [Fixtures.usbMic.id, Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        // The other microphone takes over the built-in one's lane.
        coordinator.selectDevices([Fixtures.usbMic, other, .systemAudio])
        try await waitUntil { coordinator.inputLevels[other.id] != nil }
        await coordinator.stopRecording()

        // Live tracks keep no samples, so the parts are found by length.
        let note = try #require(await writer.notes.first)
        #expect(
            note.transcript.segments == [
                TranscriptSegment(start: 0.2, end: 0.8, text: "Built-in.", speaker: "Me (MacBook Pro Microphone)"),
                TranscriptSegment(start: 2.2, end: 2.4, text: "Other.", speaker: "Me (Other Microphone)"),
            ]
        )
    }

    @Test func liveSessionFailingToStartEndsTheRecording() async throws {
        let error = TranscriptionError.modelUnavailable("broken")
        let writer = InMemoryNoteWriter()
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1)])
        let coordinator = makeCoordinator(capture: capture, engine: MockEngine(liveError: error), writer: writer)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.lastNoteURL != nil }

        #expect(coordinator.phase == .failed(message: RecordingCoordinator.interruptedMessage(for: error)))
        // Settings offers to download the model again.
        #expect(coordinator.modelError == error.localizedDescription)
        #expect(capture.stopCount == 1)
        #expect(await writer.notes.first?.transcript.isEmpty == true)
    }

    @Test func liveSessionsGetAudioInBatches() async throws {
        let live = MockLiveSession()
        // A tenth of a second at a time, like a capture's buffers.
        let chunks = (0..<10).map { Fixtures.chunk(seconds: 0.1, hostTime: 100 + Double($0) / 10) }
        let coordinator = makeCoordinator(capture: MockCapture(chunks: chunks), engine: MockEngine(liveSession: live))
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        await coordinator.stopRecording()

        // The rest is fed when the input ends.
        #expect(await live.pushedSampleCounts == [6_400, 6_400, 3_200])
        #expect(await live.finishCount == 1)
    }

    @Test func liveTranscriptionErrorKeepsTheTextSoFar() async throws {
        let error = TranscriptionError.failed("GPU lost")
        let writer = InMemoryNoteWriter()
        // The microphone's session works; the system audio's fails.
        let live = MockLiveSession(
            updatesBySampleCount: [
                16_000: LiveTranscriptUpdate(words: [LiveWord(text: "Hello.", start: 0, end: 0.5)])
            ],
            failingSampleCount: 8_000,
            pushError: error
        )
        let coordinator = makeCoordinator(
            captures: [
                Fixtures.builtInMic.id: MockCapture(chunks: [Fixtures.chunk(seconds: 1, hostTime: 100)]),
                AudioInputDevice.systemAudioID: MockCapture(chunks: [Fixtures.chunk(seconds: 0.5, hostTime: 100)]),
            ],
            engine: MockEngine(liveSession: live),
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.lastNoteURL != nil }

        #expect(coordinator.phase == .failed(message: RecordingCoordinator.interruptedMessage(for: error)))
        #expect(await writer.notes.first?.transcript.text == "Hello.")
    }

    // MARK: - Engine preparation

    @Test func failedDownloadIsAModelError() async {
        let error = TranscriptionError.modelUnavailable("offline")
        let coordinator = makeCoordinator(engine: MockEngine(isDownloaded: false, prepareError: error))
        await coordinator.monitorDevices()

        await coordinator.prepareEngine()

        #expect(coordinator.phase == .failed(message: error.localizedDescription))
        #expect(coordinator.modelError == error.localizedDescription)
        #expect(!coordinator.isModelDownloaded)
        #expect(!coordinator.canStartRecording)

        // Nothing to cancel.
        coordinator.cancelPreparation()
        #expect(coordinator.phase == .failed(message: error.localizedDescription))

        coordinator.dismissError()
        #expect(coordinator.phase == .idle)
        #expect(coordinator.modelError == nil)
    }

    @Test func laterFailureReplacesModelError() async {
        let startError = AudioCaptureError.microphonePermissionDenied
        let coordinator = makeCoordinator(
            capture: MockCapture(startError: startError),
            engine: MockEngine(prepareError: TranscriptionError.modelUnavailable("offline"))
        )
        await coordinator.monitorDevices()
        await coordinator.prepareEngine()
        #expect(coordinator.modelError != nil)

        await coordinator.startRecording()

        #expect(coordinator.phase == .failed(message: startError.localizedDescription))
        #expect(coordinator.modelError == nil)
    }

    @Test func cancelledPreparationStaysBusyUntilTheEngineHasStopped() async throws {
        let gate = Gate()
        let engine = MockEngine(isDownloaded: false, preparesUntilCancelled: true, cancellationGate: gate)
        let coordinator = makeCoordinator(engine: engine)
        await coordinator.monitorDevices()

        let first = Task { await coordinator.prepareEngine() }
        try await waitUntil { coordinator.phase == .preparingModel(progress: 0.5) }
        coordinator.cancelPreparation()

        // The engine is still winding down, so nothing else may start yet.
        #expect(coordinator.phase == .preparingModel(progress: 0.5))
        #expect(coordinator.isCancellingPreparation)
        #expect(!coordinator.canCancelPreparation)
        #expect(!coordinator.isIdle)
        #expect(coordinator.timeRemaining == nil)
        await coordinator.prepareEngine()
        #expect(await engine.prepareCount == 1)

        await gate.open()
        await first.value
        #expect(coordinator.phase == .idle)
        #expect(!coordinator.isCancellingPreparation)
        #expect(!coordinator.isModelDownloaded)

        // Now a new download can start, and be cancelled in turn.
        let second = Task { await coordinator.prepareEngine() }
        try await waitUntil { coordinator.canCancelPreparation }
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
        let capture = MockCapture()
        let engine = MockEngine(isDownloaded: false)
        let coordinator = makeCoordinator(capture: capture, engine: engine)
        await coordinator.monitorDevices()

        #expect(!coordinator.isModelDownloaded)
        #expect(coordinator.isIdle)
        #expect(!coordinator.canStartRecording)
        await coordinator.startRecording()
        #expect(coordinator.phase == .idle)
        #expect(capture.startCount == 0)

        await coordinator.prepareEngine()

        #expect(coordinator.phase == .idle)
        #expect(await engine.prepareCount == 1)
        #expect(coordinator.isModelDownloaded)
        #expect(coordinator.canStartRecording)
        await coordinator.startRecording()
        #expect(coordinator.isRecording)
    }

    @Test func modelStatusFollowsLanguage() async {
        let engine = PerLanguageEngine(installed: ["de"])
        let coordinator = makeCoordinator(engine: engine, options: TranscriptionOptions(language: "de"))
        #expect(engine.language.current == "de")
        // The engine can't tell yet.
        #expect(!coordinator.isModelDownloaded)

        await coordinator.refreshModelStatus()
        #expect(coordinator.isModelDownloaded)

        coordinator.options.language = "fr"
        #expect(engine.language.current == "fr")
        #expect(!coordinator.isModelDownloaded)

        await coordinator.prepareEngine()
        #expect(coordinator.isModelDownloaded)

        coordinator.options.language = "de"
        #expect(coordinator.isModelDownloaded)
    }

    @Test func languageChangedWhileRecordingAppliesToTheNextRecording() async throws {
        let engine = PerLanguageEngine(installed: ["de"])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            engine: engine,
            writer: writer,
            options: TranscriptionOptions(language: "de")
        )
        await coordinator.monitorDevices()
        await coordinator.refreshModelStatus()
        await coordinator.startRecording()
        #expect(coordinator.isRecording)

        coordinator.options.language = "fr"
        // The engine keeps the recording's language, whose model it has.
        #expect(engine.language.current == "de")
        #expect(coordinator.isModelDownloaded)
        await coordinator.stopRecording()

        #expect(coordinator.phase == .idle)
        #expect(await engine.transcribedLanguages == ["de"])
        #expect(try #require(await writer.notes.first).transcript.language == "de")
        // Then it follows; French isn't downloaded yet.
        #expect(engine.language.current == "fr")
        #expect(!coordinator.isModelDownloaded)
    }

    @Test func modelRemovedWhileRecordingIsDownloadedAgainBeforeTranscribing() async throws {
        let gate = Gate()
        let engine = MockEngine(preparationGate: gate)
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            engine: engine,
            writer: writer
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        engine.removeModel()

        let stopping = Task { await coordinator.stopRecording() }
        try await waitUntil { coordinator.phase == .preparingModel(progress: 0.5) }
        #expect(coordinator.isPreparingModelForRecording)
        #expect(!coordinator.isModelDownloaded)
        #expect(await engine.receivedSampleCounts.isEmpty)
        // The recording needs the model.
        coordinator.cancelPreparation()
        #expect(coordinator.phase == .preparingModel(progress: 0.5))
        await gate.open()
        await stopping.value

        #expect(coordinator.phase == .idle)
        #expect(!coordinator.isPreparingModelForRecording)
        #expect(coordinator.isModelDownloaded)
        #expect(await engine.prepareCount == 1)
        #expect(await engine.receivedSampleCounts == [16_000])
        #expect(await writer.notes.count == 1)
    }

    @Test func failedDownloadForRecordingIsAModelError() async {
        let engine = MockEngine(prepareError: TranscriptionError.modelUnavailable("offline"))
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            engine: engine,
            writer: writer
        )
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        engine.removeModel()
        await coordinator.stopRecording()

        let message = TranscriptionError.modelUnavailable("offline").localizedDescription
        #expect(coordinator.phase == .failed(message: message))
        #expect(coordinator.modelError == message)
        #expect(!coordinator.isPreparingModelForRecording)
        #expect(!coordinator.isModelDownloaded)
        #expect(await engine.receivedSampleCounts.isEmpty)
        #expect(await writer.notes.isEmpty)
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

    @Test func noteIsKeptUntilNotesFolderComesBack() async throws {
        let coordinator = makeCoordinator(capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]))
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        coordinator.noteWriter = nil
        await coordinator.stopRecording()

        let message = RecordingCoordinator.unsavedMessage(for: NoteWritingError.noFolder)
        #expect(coordinator.phase == .failed(message: message))
        #expect(coordinator.pendingNotes.count == 1)
        #expect(coordinator.lastNoteURL == nil)
        #expect(!coordinator.canStartRecording)

        let writer = InMemoryNoteWriter()
        coordinator.noteWriter = writer
        try await waitUntil { coordinator.pendingNotes.isEmpty }
        #expect(await writer.notes.count == 1)
        #expect(coordinator.lastNoteURL != nil)
        #expect(coordinator.phase == .idle)
    }

    @Test func failedWriteIsRetried() async throws {
        let coordinator = makeCoordinator(capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]))
        let writer = FlakyNoteWriter(failures: 2)
        coordinator.noteWriter = writer
        coordinator.pendingNoteRetryInterval = .milliseconds(10)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        await coordinator.stopRecording()

        let message = RecordingCoordinator.unsavedMessage(for: FlakyNoteWriter.WriteError())
        #expect(coordinator.phase == .failed(message: message))
        #expect(coordinator.pendingNotes.count == 1)

        try await waitUntil { coordinator.pendingNotes.isEmpty }
        #expect(await writer.notes.count == 1)
        #expect(coordinator.lastNoteURL != nil)
        #expect(coordinator.phase == .idle)
    }

    @Test func savingLaterLeavesNewRecordingAlone() async throws {
        let coordinator = makeCoordinator(queuedCaptures: [
            Fixtures.builtInMic.id: [
                MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
                MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            ]
        ])
        let writer = FlakyNoteWriter(failures: 1)
        coordinator.noteWriter = writer
        coordinator.pendingNoteRetryInterval = .milliseconds(200)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        await coordinator.stopRecording()
        #expect(coordinator.pendingNotes.count == 1)

        // The folder still has a writer, so recording again is allowed.
        await coordinator.startRecording()
        try await waitUntil { coordinator.pendingNotes.isEmpty }
        #expect(coordinator.isRecording)
        await coordinator.stopRecording()
        #expect(await writer.notes.count == 2)
        #expect(coordinator.phase == .idle)
    }

    @Test func pendingNotesMoveToTheNextCoordinator() async throws {
        let old = makeCoordinator(capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]))
        await old.monitorDevices()
        await old.startRecording()
        old.noteWriter = nil
        await old.stopRecording()

        let pending = old.takePendingNotes()
        #expect(pending.count == 1)
        #expect(old.pendingNotes.isEmpty)

        let writer = InMemoryNoteWriter()
        let new = RecordingCoordinator(
            deviceProvider: MockDeviceProvider(devices: Fixtures.devices),
            captureFactory: MockCaptureFactory(capture: MockCapture()),
            engine: MockEngine(),
            noteWriter: writer,
            pendingNotes: pending
        )
        try await waitUntil { new.pendingNotes.isEmpty }
        #expect(await writer.notes == pending)
        #expect(new.lastNoteURL != nil)
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
        #expect(coordinator.modelError == error.localizedDescription)
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

    // MARK: - Translation

    private static let german = Transcript(
        segments: [TranscriptSegment(start: 0, end: 1, text: "Hallo.")],
        language: "de"
    )

    @Test func translatesTranscriptAndSummarizesTheTranslation() async throws {
        let translator = MockTranslator(translation: Self.german)
        let summarizer = MockSummarizer(summary: NoteSummary(title: "Begrüßung", overview: "Jemand grüßt."))

        let (coordinator, note) = try await recordNote(summarizer: summarizer) {
            $0.translator = translator
            $0.translationLanguage = "de"
        }

        #expect(coordinator.phase == .idle)
        #expect(translator.receivedTranscripts == [note.transcript])
        #expect(translator.receivedLanguages == ["de"])
        #expect(note.transcript.text == "Hello.")
        #expect(note.translation == Self.german)
        #expect(summarizer.receivedTranscripts == [Self.german])
        #expect(note.title == "Begrüßung")
    }

    @Test func translatedCallIsWordedInTheTranslationsLanguage() async throws {
        // The summary doesn't say what language it's in, so the translation's is used.
        let summarizer = MockSummarizer(summary: NoteSummary(title: "Budgetplanung"))
        let (_, note) = try await recordNote(summarizer: summarizer, isCall: true) {
            $0.translator = MockTranslator(translation: Self.german)
            $0.translationLanguage = "de"
        }
        #expect(note.title == "Anruf zu Budgetplanung")
    }

    @Test func nothingIsTranslatedWhenOffInTheLanguageAlreadyOrSilent() async throws {
        let off = MockTranslator(translation: Self.german)
        let (_, offNote) = try await recordNote(summarizer: nil) { $0.translator = off }
        #expect(off.receivedTranscripts.isEmpty)
        #expect(offNote.translation == nil)

        let same = MockTranslator(translation: nil)
        let (sameCoordinator, sameNote) = try await recordNote(summarizer: nil) {
            $0.translator = same
            $0.translationLanguage = "en"
        }
        #expect(same.receivedTranscripts.count == 1)
        #expect(sameNote.translation == nil)
        #expect(sameCoordinator.phase == .idle)

        let silent = MockTranslator(translation: Self.german)
        let (_, silentNote) = try await recordNote(transcript: Transcript(segments: []), summarizer: nil) {
            $0.translator = silent
            $0.translationLanguage = "de"
        }
        #expect(silent.receivedTranscripts.isEmpty)
        #expect(silentNote.translation == nil)
    }

    @Test func noteIsSavedUntranslatedWhenTranslatingFailsAndSaysWhy() async throws {
        let error = TranscriptTranslationError.notInstalled(source: "en", target: "de")
        let summarizer = MockSummarizer()

        let (coordinator, note) = try await recordNote(summarizer: summarizer) {
            $0.translator = MockTranslator(error: error)
            $0.translationLanguage = "de"
        }

        #expect(coordinator.lastNoteURL != nil)
        #expect(note.translation == nil)
        #expect(summarizer.receivedTranscripts == [note.transcript])
        #expect(coordinator.phase == .failed(message: RecordingCoordinator.untranslatedMessage(for: error)))
    }
}
