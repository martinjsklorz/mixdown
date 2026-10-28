import Foundation
import Testing

@testable import MixdownCore

@MainActor
struct NotePipelineTests {
    private static let airPods = AudioInputDevice(id: "airpods", name: "AirPods", kind: .microphone)

    private func makePipeline(
        engine: any TranscriptionEngine,
        writer: InMemoryNoteWriter = InMemoryNoteWriter(),
        speakerNamer: MockSummarizer? = nil
    ) -> NotePipeline {
        let pipeline = NotePipeline(
            engine: engine,
            saver: NoteSaver(noteWriter: writer),
            summarizer: nil,
            translator: nil,
            translationLanguage: nil,
            sourceLabels: SourceLabels(),
            now: { Fixtures.startDate }
        )
        pipeline.speakerNamer = speakerNamer
        return pipeline
    }

    /// A track of `sampleCount` samples, which tells it apart for the mock engine, said to be
    /// `duration` seconds long.
    private func track(
        lane: Int,
        device: AudioInputDevice,
        parts: [NotePipeline.DevicePart]? = nil,
        sampleCount: Int,
        duration: TimeInterval = 10,
        offset: TimeInterval = 0
    ) -> NotePipeline.RecordedTrack {
        NotePipeline.RecordedTrack(
            lane: lane,
            device: device,
            parts: parts ?? [NotePipeline.DevicePart(device: device, start: 0)],
            samples: Array(repeating: 0.1, count: sampleCount),
            speech: [],
            duration: duration,
            offset: offset
        )
    }

    private func input(
        _ tracks: [NotePipeline.RecordedTrack],
        liveText: LiveTranscript? = nil,
        diarizer: (any SpeakerDiarizer)? = nil,
        talkTimeline: TalkTimeline? = nil,
        recordingID: UUID? = nil
    ) -> NotePipeline.Input {
        NotePipeline.Input(
            tracks: tracks,
            options: TranscriptionOptions(),
            liveText: liveText,
            diarizer: diarizer,
            details: NotePipeline.NoteDetails(
                startedAt: Fixtures.startDate,
                duration: tracks.map(\.end).max() ?? 0,
                sources: tracks.map(\.device),
                trigger: .manual,
                isCall: true,
                talkTimeline: talkTimeline,
                recordingID: recordingID
            )
        )
    }

    private func update(_ text: String, at start: TimeInterval) -> LiveTranscriptUpdate {
        LiveTranscriptUpdate(words: [LiveWord(text: text, start: start, end: start + 0.5)])
    }

    // MARK: - Labels

    @Test func aLaneThatSwitchedMicrophonesIsLabeledByDevice() async throws {
        let engine = MockEngine(transcriptsBySampleCount: [
            100: Transcript(segments: [
                TranscriptSegment(start: 2, end: 3, text: "On the laptop."),
                TranscriptSegment(start: 12, end: 13, text: "On the AirPods."),
            ]),
            200: Transcript(segments: [TranscriptSegment(start: 1, end: 2, text: "On the USB one.")]),
        ])
        let writer = InMemoryNoteWriter()
        let pipeline = makePipeline(engine: engine, writer: writer)
        let switched = track(
            lane: 0,
            device: Fixtures.builtInMic,
            parts: [
                NotePipeline.DevicePart(device: Fixtures.builtInMic, start: 0),
                NotePipeline.DevicePart(device: Self.airPods, start: 10),
            ],
            sampleCount: 100,
            duration: 20
        )
        let tracks = [switched, track(lane: 1, device: Fixtures.usbMic, sampleCount: 200, offset: 5)]

        _ = try await pipeline.makeNote(from: input(tracks)) { .general }

        let note = try #require(await writer.notes.first)
        #expect(
            note.transcript.segments.map { "\($0.speaker ?? ""): \($0.text)" } == [
                "Me (MacBook Pro Microphone): On the laptop.",
                "Me (USB Microphone): On the USB one.",
                "Me (AirPods): On the AirPods.",
            ]
        )
    }

    @Test func theSpeakersToldApartOnSystemAudioAreNamed() async throws {
        let engine = MockEngine(transcriptsBySampleCount: [
            100: Transcript(segments: [TranscriptSegment(start: 0, end: 2, text: "Hello everyone.")]),
            200: Transcript(segments: [
                TranscriptSegment(start: 0, end: 4, text: "Hi, I'm Anna and I run the project."),
                TranscriptSegment(start: 6, end: 10, text: "I'm Ben, I look after the budget."),
            ]),
        ])
        let diarizer = MockDiarizer(turnsBySampleCount: [
            200: [SpeakerTurn(start: 0, end: 5, speaker: 0), SpeakerTurn(start: 5, end: 10, speaker: 1)]
        ])
        let namer = MockSummarizer(speakerNames: ["Others (Speaker 1)": "Anna"])
        let writer = InMemoryNoteWriter()
        let pipeline = makePipeline(engine: engine, writer: writer, speakerNamer: namer)
        let tracks = [
            track(lane: 0, device: Fixtures.builtInMic, sampleCount: 100),
            track(lane: 1, device: .systemAudio, sampleCount: 200, offset: 20),
        ]

        _ = try await pipeline.makeNote(from: input(tracks, diarizer: diarizer)) { .general }

        #expect(namer.receivedNamings.map(\.speakers) == [["Others (Speaker 1)", "Others (Speaker 2)"]])
        let note = try #require(await writer.notes.first)
        #expect(note.transcript.speakers == ["Me", "Anna", "Others (Speaker 2)"])
        // The diarizer's turns count from the track's first sample, like its transcript.
        #expect(note.transcript.segments.map(\.start) == [0, 20, 26])
    }

    @Test func theOnePersonOnSystemAudioIsNamedInTheTalkTimelineToo() async throws {
        let engine = MockEngine(transcriptsBySampleCount: [
            100: Transcript(segments: [TranscriptSegment(start: 0, end: 2, text: "Who's this?")]),
            200: Transcript(segments: [TranscriptSegment(start: 3, end: 5, text: "It's Anna.")]),
        ])
        let diarizer = MockDiarizer(turnsBySampleCount: [200: [SpeakerTurn(start: 0, end: 10, speaker: 0)]])
        let namer = MockSummarizer(speakerNames: ["Others": "Anna"])
        let writer = InMemoryNoteWriter()
        let pipeline = makePipeline(engine: engine, writer: writer, speakerNamer: namer)
        let tracks = [
            track(lane: 0, device: Fixtures.builtInMic, sampleCount: 100),
            track(lane: 1, device: .systemAudio, sampleCount: 200),
        ]
        let timeline = TalkTimeline(
            microphoneLabel: "Me",
            systemAudioLabel: "Others",
            microphone: [2],
            systemAudio: [2]
        )

        _ = try await pipeline.makeNote(from: input(tracks, diarizer: diarizer, talkTimeline: timeline)) { .general }

        #expect(namer.receivedNamings.map(\.speakers) == [["Others"]])
        let note = try #require(await writer.notes.first)
        #expect(note.transcript.speakers == ["Me", "Anna"])
        #expect(note.talkTimeline?.microphoneLabel == "Me")
        #expect(note.talkTimeline?.systemAudioLabel == "Anna")
    }

    @Test func theTalkTimelineIsLabeledAsTheTranscript() async throws {
        let engine = MockEngine(transcriptsBySampleCount: [
            100: Transcript(segments: [TranscriptSegment(start: 0, end: 2, text: "Hello.")]),
            200: Transcript(segments: [TranscriptSegment(start: 3, end: 5, text: "Hi.")]),
        ])
        let writer = InMemoryNoteWriter()
        let pipeline = makePipeline(engine: engine, writer: writer)
        let tracks = [
            track(lane: 0, device: Fixtures.builtInMic, sampleCount: 100),
            track(lane: 1, device: .systemAudio, sampleCount: 200),
        ]
        let timeline = TalkTimeline(
            microphoneLabel: "Me",
            systemAudioLabel: "Others",
            microphone: [2],
            systemAudio: [2]
        )
        // Renamed while the recording was transcribed.
        pipeline.sourceLabels = SourceLabels(microphone: "Max", systemAudio: "Team")

        _ = try await pipeline.makeNote(from: input(tracks, talkTimeline: timeline)) { .general }

        let note = try #require(await writer.notes.first)
        #expect(note.transcript.speakers == ["Max", "Team"])
        #expect(note.talkTimeline?.microphoneLabel == "Max")
        #expect(note.talkTimeline?.systemAudioLabel == "Team")
    }

    // MARK: - Live text

    @Test func liveTextAfterASilentFirstCaptureIsPlacedFromTheLanesFirstSample() async throws {
        var liveText = LiveTranscript(speakers: [nil, nil])
        // The first microphone heard nothing for a minute, then the lane switched to AirPods,
        // whose live session counts its times from zero again.
        liveText.apply(LiveTranscriptUpdate(), fromSource: 0, startHostTime: 100)
        liveText.apply(update("Hi.", at: 30), fromSource: 1, startHostTime: 100)
        liveText.apply(update("After.", at: 0), fromSource: 0, startHostTime: 160)
        #expect(liveText.segments(fromSource: 0) == [TranscriptSegment(start: 60, end: 60.5, text: "After.")])

        let writer = InMemoryNoteWriter()
        let pipeline = makePipeline(engine: MockEngine(), writer: writer)
        let switched = track(
            lane: 0,
            device: Fixtures.builtInMic,
            parts: [
                NotePipeline.DevicePart(device: Fixtures.builtInMic, start: 0),
                NotePipeline.DevicePart(device: Self.airPods, start: 60),
            ],
            sampleCount: 0,
            duration: 90
        )
        let tracks = [switched, track(lane: 1, device: .systemAudio, sampleCount: 0, duration: 90)]

        _ = try await pipeline.makeNote(from: input(tracks, liveText: liveText)) { .general }

        let note = try #require(await writer.notes.first)
        #expect(
            note.transcript.segments == [
                TranscriptSegment(start: 30, end: 30.5, text: "Hi.", speaker: "Others"),
                TranscriptSegment(start: 60, end: 60.5, text: "After.", speaker: "Me"),
            ]
        )
    }

    @Test func aLiveEngineTranscribesEachTrackOnItsTimeline() async throws {
        let piece = NotePipeline.liveFeedSampleCount
        // Each track's last piece is a different size, which tells their words apart.
        let session = MockLiveSession(updatesBySampleCount: [
            640: update("Hello.", at: 1),
            740: update("Hi.", at: 1),
        ])
        let writer = InMemoryNoteWriter()
        let pipeline = makePipeline(engine: MockEngine(liveSession: session), writer: writer)
        let tracks = [
            track(lane: 0, device: Fixtures.builtInMic, sampleCount: 3 * piece + 640),
            track(lane: 1, device: .systemAudio, sampleCount: 3 * piece + 740, offset: 2),
        ]

        let outcome = try await pipeline.makeNote(from: input(tracks)) { .general }

        #expect(outcome.isComplete)
        #expect(await session.pushedSampleCounts == [piece, piece, piece, 640, piece, piece, piece, 740])
        let note = try #require(await writer.notes.first)
        #expect(
            note.transcript.segments == [
                TranscriptSegment(start: 1, end: 1.5, text: "Hello.", speaker: "Me"),
                TranscriptSegment(start: 3, end: 3.5, text: "Hi.", speaker: "Others"),
            ]
        )
    }

    @Test func aTrackALiveEngineFailsOnLeavesTheOthers() async throws {
        let piece = NotePipeline.liveFeedSampleCount
        let session = MockLiveSession(updatesBySampleCount: [640: update("Hello.", at: 1)], failingSampleCount: 740)
        let writer = InMemoryNoteWriter()
        let pipeline = makePipeline(engine: MockEngine(liveSession: session), writer: writer)
        // An imported track has no parts; it's still named.
        let failing = track(lane: 1, device: .systemAudio, parts: [], sampleCount: piece + 740)
        let tooShort = track(lane: 2, device: Fixtures.usbMic, sampleCount: 3_000, duration: 0.2)
        let tracks = [track(lane: 0, device: Fixtures.builtInMic, sampleCount: piece + 640), failing, tooShort]

        let outcome = try await pipeline.makeNote(from: input(tracks, recordingID: UUID())) { .general }

        #expect(!outcome.isComplete)
        #expect(outcome.trackFailure?.devices == [.systemAudio])
        #expect(RecordingCoordinator.messages(for: outcome).count == 1)
        // Too short to transcribe, like for an offline engine.
        #expect(await !session.pushedSampleCounts.contains(3_000))
        let note = try #require(await writer.notes.first)
        #expect(note.transcript.segments.map(\.text) == ["Hello."])
        // Kept to transcribe again.
        #expect(note.recordingID == nil)
    }

    // MARK: - Failures

    @Test func aFailedTrackWithNoSpeechFromTheOthersFailsTheNote() async throws {
        let error = TranscriptionError.failed("No")
        let engine = MockEngine(transcribeErrorsBySampleCount: [200: error])
        let writer = InMemoryNoteWriter()
        let pipeline = makePipeline(engine: engine, writer: writer)
        let tracks = [
            track(lane: 0, device: Fixtures.builtInMic, sampleCount: 100),
            track(lane: 1, device: .systemAudio, sampleCount: 200),
        ]

        await #expect(throws: TranscriptionError.self) {
            _ = try await pipeline.makeNote(from: input(tracks)) { .general }
        }
        #expect(await writer.notes.isEmpty)
    }

    @Test func aFailedTrackIsReportedByEveryDeviceItRecorded() async throws {
        let error = TranscriptionError.failed("No")
        let engine = MockEngine(
            transcriptsBySampleCount: [200: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "Hi.")])],
            transcribeErrorsBySampleCount: [100: error]
        )
        let pipeline = makePipeline(engine: engine)
        let switched = track(
            lane: 0,
            device: Fixtures.builtInMic,
            parts: [
                NotePipeline.DevicePart(device: Fixtures.builtInMic, start: 0),
                NotePipeline.DevicePart(device: Self.airPods, start: 5),
            ],
            sampleCount: 100
        )
        let tracks = [switched, track(lane: 1, device: .systemAudio, sampleCount: 200)]

        let outcome = try await pipeline.makeNote(from: input(tracks)) { .general }

        #expect(outcome.trackFailure?.devices == [Fixtures.builtInMic, Self.airPods])
        #expect(outcome.translationError == nil)
        #expect(outcome.saveError == nil)
        #expect(
            RecordingCoordinator.messages(for: outcome) == [
                RecordingCoordinator.untranscribedMessage(for: [Fixtures.builtInMic, Self.airPods], error: error)
            ]
        )
    }

    // MARK: - Progress

    @Test func progressIsWeightedByTrackLength() {
        var progress = NotePipeline.TranscriptionProgress(sampleCounts: [100, 300])
        progress.fractions = [1, 0.5]
        #expect(progress.total == 0.625)
        #expect(NotePipeline.TranscriptionProgress(sampleCounts: [0, 0]).total == 0)
    }

    @Test func aLiveEngineReportsEachTrackDoneByItsShare() async throws {
        let session = MockLiveSession(updatesBySampleCount: [640: update("Hello.", at: 0)])
        let pipeline = makePipeline(engine: MockEngine(liveSession: session))
        var stages: [NotePipeline.Stage] = []
        pipeline.didChangeStage = { stages.append($0) }
        // A quarter of the samples, then the rest.
        let tracks = [
            track(lane: 0, device: Fixtures.builtInMic, sampleCount: 640),
            track(lane: 1, device: .systemAudio, sampleCount: 1_920),
        ]

        _ = try await pipeline.makeNote(from: input(tracks)) { .general }

        #expect(stages == [.transcribing(progress: 0), .transcribing(progress: 0.25), .transcribing(progress: 1)])
        // The progress and estimate don't outlive the transcription.
        #expect(pipeline.transcriptionProgress == nil)
        #expect(pipeline.timeRemaining == nil)
    }
}
