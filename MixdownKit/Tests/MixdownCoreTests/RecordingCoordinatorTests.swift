import Foundation
import Testing

@testable import MixdownCore

@MainActor
struct RecordingCoordinatorTests {
    private func makeCoordinator(
        devices: [AudioInputDevice] = Fixtures.devices,
        updates: [[AudioInputDevice]] = [],
        capture: MockCapture = MockCapture(),
        captures: [String: MockCapture] = [:],
        queuedCaptures: [String: [MockCapture]] = [:],
        engine: any TranscriptionEngine = MockEngine(),
        writer: InMemoryNoteWriter = InMemoryNoteWriter(),
        summarizer: MockSummarizer? = nil,
        options: TranscriptionOptions = .init(),
        preferredDeviceIDs: [String] = [],
        echoCancellation: (any EchoCancellation)? = nil,
        now: @escaping @Sendable () -> Date = { Fixtures.startDate },
        hostClock: @escaping @Sendable () -> TimeInterval = { 0 }
    ) -> RecordingCoordinator {
        let coordinator = RecordingCoordinator(
            deviceProvider: MockDeviceProvider(devices: devices, updates: updates),
            captureFactory: MockCaptureFactory(capture: capture, captures: captures, queuedCaptures: queuedCaptures),
            engine: engine,
            noteWriter: writer,
            summarizer: summarizer,
            options: options,
            preferredDeviceIDs: preferredDeviceIDs,
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

    @Test func correctsTranscriptWithVocabularyBeforeSummarizing() async throws {
        let summarizer = MockSummarizer(summary: NoteSummary(overview: "A migration."))
        let (_, note) = try await recordNote(
            transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "We move to cooper netties.")]),
            summarizer: summarizer,
            configure: {
                $0.vocabulary = Vocabulary(entries: [.init(term: "Kubernetes", soundsLike: ["cooper netties"])])
            }
        )

        #expect(note.transcript.text == "We move to Kubernetes.")
        #expect(summarizer.receivedTranscripts == [note.transcript])
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

    @Test func editsToTheRecordingsTemplateReachItsSummary() async throws {
        let summarizer = MockSummarizer()
        var edited = SummaryTemplate.standup
        edited.instructions = "Look out for blockers."
        let other = SummaryTemplate(id: "custom-1", name: "Other")
        _ = try await recordNote(
            summarizer: summarizer,
            configure: { $0.summaryTemplate = .standup },
            whileRecording: { coordinator in
                coordinator.updateRecordingSummaryTemplate(from: [other])
                coordinator.updateRecordingSummaryTemplate(from: [.general, edited, other])
            }
        )

        #expect(summarizer.receivedTemplates == [edited])
    }

    @Test func noteIsSavedWithoutSummaryWhenSummarizingFails() async throws {
        let summarizer = MockSummarizer(error: SummarizationError.failed("guardrail"))

        let (coordinator, note) = try await recordNote(summarizer: summarizer)

        #expect(coordinator.phase == .idle)
        #expect(coordinator.lastNoteURL != nil)
        #expect(note.summary == nil)
        #expect(summarizer.receivedTranscripts.count == 1)
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

    // MARK: - Talk time

    @Test func timesEachSideTalkingFromItsOwnTrack() async throws {
        // The system audio starts a second after the microphone, according to the host clock.
        let microphone = MockCapture(
            chunks: [AudioChunk(samples: TalkFixtures.audio([true, false, true]), hostTime: 100)]
        )
        let systemAudio = MockCapture(
            chunks: [AudioChunk(samples: TalkFixtures.audio([false, true, true]), hostTime: 101)]
        )
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [Fixtures.builtInMic.id: microphone, AudioInputDevice.systemAudioID: systemAudio],
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        coordinator.sourceLabels = SourceLabels(microphone: "Martin", systemAudio: "Client")
        coordinator.measuresTalkTime = true
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        #expect(coordinator.talkTime != nil)
        await coordinator.stopRecording()
        #expect(coordinator.talkTime == nil)

        let timeline = try #require(await writer.notes.first?.talkTimeline)
        #expect(timeline.microphoneLabel == "Martin")
        #expect(timeline.systemAudioLabel == "Client")
        #expect(timeline.minuteCount == 1)
        #expect(abs(timeline.microphone[0] - 2) < 0.001)
        #expect(abs(timeline.systemAudio[0] - 2) < 0.001)
    }

    @Test func measuresNoTalkTimeByDefault() async throws {
        let microphone = MockCapture(
            chunks: [AudioChunk(samples: TalkFixtures.audio([true, false, true]), hostTime: 100)]
        )
        let systemAudio = MockCapture(
            chunks: [AudioChunk(samples: TalkFixtures.audio([false, true, true]), hostTime: 101)]
        )
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [Fixtures.builtInMic.id: microphone, AudioInputDevice.systemAudioID: systemAudio],
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        #expect(coordinator.talkTime == nil)
        await coordinator.stopRecording()

        let note = try #require(await writer.notes.first)
        #expect(note.talkTimeline == nil)
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

    // MARK: - Catching up

    /// A live recording of one input that said "Hello everyone." at 10 s and "The budget is
    /// approved." at 90 s, and the clock it reads the time from, at its start.
    private func makeCatchUpCoordinator() -> (RecordingCoordinator, LockedValue<Date>) {
        let date = LockedValue(Fixtures.startDate)
        let live = MockLiveSession(updatesBySampleCount: [
            16_000: LiveTranscriptUpdate(words: [
                LiveWord(text: "Hello", start: 10, end: 10.5),
                LiveWord(text: "everyone.", start: 10.5, end: 11),
                LiveWord(text: "The", start: 90, end: 90.25),
                LiveWord(text: "budget", start: 90.25, end: 90.5),
                LiveWord(text: "is", start: 90.5, end: 90.75),
                LiveWord(text: "approved.", start: 90.75, end: 91),
            ])
        ])
        let coordinator = makeCoordinator(
            capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]),
            engine: MockEngine(liveSession: live),
            now: { date.current }
        )
        return (coordinator, date)
    }

    @Test func catchUpSumsUpTheLastMinutesOfLiveText() async throws {
        let summarizer = MockSummarizer(summary: NoteSummary(keyPoints: [" The budget was approved. ", " "]))
        let (coordinator, date) = makeCatchUpCoordinator()
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        try await waitUntil { coordinator.liveTranscript.lines.count == 2 }

        date.update { $0 = Fixtures.startDate.addingTimeInterval(100) }
        let catchUp = try await coordinator.catchUp(onLast: 60, with: summarizer)

        #expect(catchUp == CatchUp(duration: 60, points: ["The budget was approved."]))
        let received = try #require(summarizer.receivedCatchUps.first)
        #expect(received.transcript.text == "The budget is approved.")
        #expect(received.language == nil)
        // Not a summary of the note.
        #expect(summarizer.receivedTranscripts.isEmpty)

        // Less than asked for, so far.
        let all = try await coordinator.catchUp(onLast: 300, with: summarizer)
        #expect(all.duration == 100)
        #expect(summarizer.receivedCatchUps.last?.transcript.text == "Hello everyone. The budget is approved.")
        await coordinator.stopRecording()
    }

    @Test func catchUpSaysWhyItCant() async throws {
        let summarizer = MockSummarizer(summary: NoteSummary(keyPoints: ["Something."]))
        let (coordinator, date) = makeCatchUpCoordinator()
        await coordinator.monitorDevices()
        await #expect(throws: CatchUpError.notRecording) {
            try await coordinator.catchUp(onLast: 60, with: summarizer)
        }

        await coordinator.startRecording()
        try await waitUntil { coordinator.liveTranscript.lines.count == 2 }
        // Silence since 91 s.
        date.update { $0 = Fixtures.startDate.addingTimeInterval(200) }
        await #expect(throws: CatchUpError.nothingSaid) {
            try await coordinator.catchUp(onLast: 60, with: summarizer)
        }
        // The summarizer finds nothing worth a point.
        await #expect(throws: CatchUpError.nothingSaid) {
            try await coordinator.catchUp(onLast: 300, with: MockSummarizer(summary: NoteSummary()))
        }
        let unavailable = MockSummarizer(availability: .unavailable(reason: "Turn it on."))
        await #expect(throws: SummarizationError.unavailable("Turn it on.")) {
            try await coordinator.catchUp(onLast: 300, with: unavailable)
        }
        #expect(unavailable.receivedCatchUps.isEmpty)
        await coordinator.stopRecording()
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

        try await waitUntil { !coordinator.silentDevices.isEmpty }
        #expect(coordinator.silentDevices == [.systemAudio])

        await coordinator.stopRecording()
        #expect(coordinator.inputLevels.isEmpty)
        #expect(coordinator.silentDevices.isEmpty)
    }

    // MARK: - Still recording?

    @Test func asksIfStillRecordingAfterNoSpeech() async throws {
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1, amplitude: 0)])
        let coordinator = makeCoordinator(capture: capture)
        coordinator.stillRecordingDelay = .milliseconds(50)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        #expect(!coordinator.isAskingIfStillRecording)
        try await waitUntil { coordinator.isAskingIfStillRecording }

        await coordinator.stopRecording()
        #expect(!coordinator.isAskingIfStillRecording)
    }

    @Test func speechAnswersStillRecording() async throws {
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1, amplitude: 0)])
        let coordinator = makeCoordinator(capture: capture)
        coordinator.stillRecordingDelay = .milliseconds(50)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.isAskingIfStillRecording }

        // Loud after silence, so it's speech.
        capture.yield(Fixtures.chunk(seconds: 0.2))
        try await waitUntil { !coordinator.isAskingIfStillRecording }

        await coordinator.stopRecording()
    }

    @Test func keepRecordingAsksAgainOnlyAfterAnotherDelay() async throws {
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1, amplitude: 0)])
        let coordinator = makeCoordinator(capture: capture)
        coordinator.stillRecordingDelay = .milliseconds(300)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.isAskingIfStillRecording }

        coordinator.keepRecording()
        #expect(!coordinator.isAskingIfStillRecording)
        #expect(coordinator.isRecording)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!coordinator.isAskingIfStillRecording)
        try await waitUntil { coordinator.isAskingIfStillRecording }

        await coordinator.stopRecording()
    }

    @Test func neverAsksIfStillRecordingWhenTurnedOff() async throws {
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1, amplitude: 0)])
        let coordinator = makeCoordinator(capture: capture)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!coordinator.isAskingIfStillRecording)

        // Turned on mid-recording, it counts from then.
        coordinator.stillRecordingDelay = .milliseconds(50)
        try await waitUntil { coordinator.isAskingIfStillRecording }

        coordinator.stillRecordingDelay = nil
        #expect(!coordinator.isAskingIfStillRecording)

        await coordinator.stopRecording()
    }

    @Test func pausingAnswersStillRecording() async throws {
        let capture = MockCapture(chunks: [Fixtures.chunk(seconds: 1, amplitude: 0)])
        let coordinator = makeCoordinator(capture: capture)
        coordinator.stillRecordingDelay = .milliseconds(50)
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.isAskingIfStillRecording }

        await coordinator.pauseRecording()
        #expect(!coordinator.isAskingIfStillRecording)
        // Paused time doesn't count.
        try await Task.sleep(for: .milliseconds(150))
        #expect(!coordinator.isAskingIfStillRecording)

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

    // MARK: - Speakers

    @Test func tellsSystemAudioSpeakersApartAndNamesThem() async throws {
        let microphone = MockCapture(chunks: [Fixtures.chunk(seconds: 2, hostTime: 100)])
        let systemAudio = MockCapture(chunks: [Fixtures.chunk(seconds: 3, hostTime: 100)])
        let engine = MockEngine(transcriptsBySampleCount: [
            32_000: Transcript(segments: [TranscriptSegment(start: 0.2, end: 0.5, text: "Hello.")]),
            48_000: Transcript(segments: [TranscriptSegment(start: 0, end: 3, text: "Hi, I'm Anna. And I'm Tom.")]),
        ])
        let diarizer = MockDiarizer(turnsBySampleCount: [
            48_000: [SpeakerTurn(start: 0, end: 1.5, speaker: 0), SpeakerTurn(start: 1.5, end: 3, speaker: 1)]
        ])
        let namer = MockSummarizer(speakerNames: ["Others (Speaker 1)": "Anna"])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [Fixtures.builtInMic.id: microphone, AudioInputDevice.systemAudioID: systemAudio],
            engine: engine,
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        coordinator.speakerDiarizer = diarizer
        coordinator.speakerNamer = namer
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        await coordinator.stopRecording()

        #expect(coordinator.phase == .idle)
        // Only the system audio.
        #expect(diarizer.receivedSampleCounts == [48_000])
        #expect(namer.receivedNamings.map(\.speakers) == [["Others (Speaker 1)", "Others (Speaker 2)"]])
        let note = try #require(await writer.notes.first)
        #expect(note.transcript.segments.map(\.text) == ["Hi, I'm Anna.", "Hello.", "And I'm Tom."])
        #expect(note.transcript.segments.map(\.speaker) == ["Anna", "Me", "Others (Speaker 2)"])
    }

    @Test func liveTextIsSplitBetweenSpeakersByItsWordTimes() async throws {
        // The system audio starts a second after the microphone, according to the host clock.
        let live = MockLiveSession(updatesBySampleCount: [
            32_000: LiveTranscriptUpdate(words: [LiveWord(text: "Morning.", start: 0.25, end: 0.75)]),
            16_000: LiveTranscriptUpdate(words: [
                LiveWord(text: "Hi!", start: 0, end: 0.25),
                LiveWord(text: "Bye.", start: 0.5, end: 0.75),
            ]),
        ])
        let diarizer = MockDiarizer(turnsBySampleCount: [
            16_000: [SpeakerTurn(start: 0, end: 0.4, speaker: 0), SpeakerTurn(start: 0.4, end: 1, speaker: 1)]
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
        coordinator.speakerDiarizer = diarizer
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        try await waitUntil { coordinator.liveTranscript.lines.count == 2 }
        await coordinator.stopRecording()

        // The system audio was kept for it; the microphone wasn't.
        #expect(diarizer.receivedSampleCounts == [16_000])
        #expect(
            await writer.notes.first?.transcript.segments == [
                TranscriptSegment(start: 0.25, end: 0.75, text: "Morning.", speaker: "Me"),
                TranscriptSegment(start: 1, end: 1.25, text: "Hi!", speaker: "Others (Speaker 1)"),
                TranscriptSegment(start: 1.5, end: 1.75, text: "Bye.", speaker: "Others (Speaker 2)"),
            ]
        )
    }

    @Test func noteIsSavedWithoutSpeakersWhenTellingThemApartFails() async throws {
        let engine = MockEngine(transcriptsBySampleCount: [
            32_000: Transcript(segments: [TranscriptSegment(start: 0.2, end: 0.5, text: "Hello.")]),
            48_000: Transcript(segments: [TranscriptSegment(start: 0, end: 3, text: "Hi there.")]),
        ])
        let namer = MockSummarizer(speakerNames: ["Others": "Anna"])
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            captures: [
                Fixtures.builtInMic.id: MockCapture(chunks: [Fixtures.chunk(seconds: 2, hostTime: 100)]),
                AudioInputDevice.systemAudioID: MockCapture(chunks: [Fixtures.chunk(seconds: 3, hostTime: 100)]),
            ],
            engine: engine,
            writer: writer,
            preferredDeviceIDs: [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID]
        )
        coordinator.speakerDiarizer = MockDiarizer(error: TranscriptionError.failed("broken"))
        coordinator.speakerNamer = namer
        await coordinator.monitorDevices()

        await coordinator.startRecording()
        await coordinator.stopRecording()

        #expect(coordinator.phase == .idle)
        // Without speakers told apart, "Others" may be several people.
        #expect(namer.receivedNamings.isEmpty)
        #expect(await writer.notes.first?.transcript.segments.map(\.speaker) == ["Others", "Me"])
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
