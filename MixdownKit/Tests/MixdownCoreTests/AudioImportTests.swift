import Foundation
import Testing

@testable import MixdownCore

@MainActor
struct AudioImportTests {
    private let file = URL(fileURLWithPath: "/Users/me/Recordings/Budget review.m4a")
    private let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let hello = Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "Hello.")])

    private func makeCoordinator(
        decoder: MockAudioFileDecoder? = MockAudioFileDecoder(),
        engine: any TranscriptionEngine = MockEngine(),
        writer: InMemoryNoteWriter = InMemoryNoteWriter(),
        summarizer: MockSummarizer? = nil
    ) -> RecordingCoordinator {
        RecordingCoordinator(
            deviceProvider: MockDeviceProvider(devices: Fixtures.devices),
            captureFactory: MockCaptureFactory(capture: MockCapture()),
            engine: engine,
            noteWriter: writer,
            summarizer: summarizer,
            audioFileDecoder: decoder,
            now: { Fixtures.startDate }
        )
    }

    @Test func importsFileAsNoteNamedAfterIt() async throws {
        let writer = InMemoryNoteWriter()
        let engine = MockEngine(transcript: hello)
        let coordinator = makeCoordinator(
            decoder: MockAudioFileDecoder(
                audio: DecodedAudio(samples: [Float](repeating: 0.1, count: 32_000), recordedAt: recordedAt)
            ),
            engine: engine,
            writer: writer
        )
        #expect(coordinator.canImportAudio)

        await coordinator.importAudio(from: file)

        let note = try #require(await writer.notes.first)
        #expect(note.title == "Budget review")
        #expect(note.createdAt == recordedAt)
        #expect(note.duration == 2)
        #expect(note.sources == [.importedFile(at: file)])
        #expect(note.sources.first?.name == "Budget review.m4a")
        #expect(note.sources.first?.kind == .file)
        #expect(note.trigger == .imported)
        #expect(!note.isCall)
        #expect(note.transcript == hello)
        #expect(await engine.receivedSampleCounts == [32_000])
        #expect(coordinator.phase == .idle)
        #expect(coordinator.importingFileName == nil)
        #expect(coordinator.lastNoteURL != nil)
        #expect(engine.recordingsInProgress.current == 0)
    }

    @Test func datesNoteNowWhenFileDoesNotSay() async throws {
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(writer: writer)

        await coordinator.importAudio(from: file)

        #expect(try #require(await writer.notes.first).createdAt == Fixtures.startDate)
    }

    @Test func summaryTitleWinsOverFileName() async throws {
        let writer = InMemoryNoteWriter()
        let summarizer = MockSummarizer(summary: NoteSummary(title: "Q3 budget", overview: "Numbers."))
        let coordinator = makeCoordinator(engine: MockEngine(transcript: hello), writer: writer, summarizer: summarizer)

        await coordinator.importAudio(from: file)

        let note = try #require(await writer.notes.first)
        #expect(note.title == "Q3 budget")
        #expect(note.template == .general)
        #expect(summarizer.receivedTranscripts == [hello])
    }

    @Test func summarizesWithTemplateChosenWhileImporting() async throws {
        let writer = InMemoryNoteWriter()
        let gate = Gate()
        let summarizer = MockSummarizer()
        let coordinator = makeCoordinator(
            decoder: MockAudioFileDecoder(gate: gate),
            engine: MockEngine(transcript: hello),
            writer: writer,
            summarizer: summarizer
        )

        let importing = Task { await coordinator.importAudio(from: file) }
        try await waitUntil { coordinator.importingFileName == "Budget review.m4a" }
        #expect(coordinator.recordingSummaryTemplate == .general)
        #expect(!coordinator.canImportAudio)
        #expect(!coordinator.canStartRecording)
        #expect(coordinator.isMakingNote)
        coordinator.chooseSummaryTemplate(.standup)
        await gate.open()
        await importing.value

        #expect(summarizer.receivedTemplates == [.standup])
        #expect(coordinator.recordingSummaryTemplate == nil)
        #expect(!coordinator.isMakingNote)
    }

    @Test func liveEngineIsFedTheFileInPieces() async throws {
        let writer = InMemoryNoteWriter()
        let piece = RecordingCoordinator.liveFeedSampleCount
        let session = MockLiveSession(
            updatesBySampleCount: [100: LiveTranscriptUpdate(words: [LiveWord(text: "Hello.", start: 0.1, end: 0.5)])],
            finishUpdate: LiveTranscriptUpdate(words: [LiveWord(text: "Bye.", start: 0.6, end: 0.9)])
        )
        let coordinator = makeCoordinator(
            decoder: MockAudioFileDecoder(audio: DecodedAudio(samples: [Float](repeating: 0, count: piece * 2 + 100))),
            engine: MockEngine(liveSession: session),
            writer: writer
        )

        await coordinator.importAudio(from: file)

        #expect(await session.pushedSampleCounts == [piece, piece, 100])
        #expect(await session.finishCount == 1)
        let note = try #require(await writer.notes.first)
        #expect(note.transcript.text == "Hello. Bye.")
        #expect(coordinator.phase == .idle)
    }

    @Test func tooShortFileFailsWithoutNote() async {
        let writer = InMemoryNoteWriter()
        let coordinator = makeCoordinator(
            decoder: MockAudioFileDecoder(audio: DecodedAudio(samples: [Float](repeating: 0, count: 100))),
            writer: writer
        )

        await coordinator.importAudio(from: file)

        let message = RecordingCoordinator.tooShortImportMessage(for: "Budget review.m4a")
        #expect(coordinator.phase == .failed(message: message))
        #expect(await writer.notes.isEmpty)
        #expect(coordinator.importingFileName == nil)
    }

    @Test func unreadableFileFails() async {
        let writer = InMemoryNoteWriter()
        let error = AudioImportError.noAudio("Budget review.m4a")
        let coordinator = makeCoordinator(decoder: MockAudioFileDecoder(error: error), writer: writer)

        await coordinator.importAudio(from: file)

        #expect(coordinator.phase == .failed(message: error.localizedDescription))
        #expect(await writer.notes.isEmpty)
    }

    @Test func cancellingSavesNothing() async throws {
        let writer = InMemoryNoteWriter()
        let gate = Gate()
        let engine = MockEngine(transcript: hello)
        let coordinator = makeCoordinator(decoder: MockAudioFileDecoder(gate: gate), engine: engine, writer: writer)

        let importing = Task { await coordinator.importAudio(from: file) }
        try await waitUntil { coordinator.importingFileName != nil }
        coordinator.cancelImport()
        await gate.open()
        await importing.value

        #expect(coordinator.phase == .idle)
        #expect(coordinator.isIdle)
        #expect(await writer.notes.isEmpty)
        #expect(await engine.receivedSampleCounts.isEmpty)
        #expect(engine.recordingsInProgress.current == 0)
    }

    @Test func needsDecoderModelAndFolder() async {
        #expect(!makeCoordinator(decoder: nil).canImportAudio)
        #expect(!makeCoordinator(engine: MockEngine(isDownloaded: false)).canImportAudio)
        let coordinator = makeCoordinator()
        coordinator.noteWriter = nil
        #expect(!coordinator.canImportAudio)

        await coordinator.importAudio(from: file)
        #expect(coordinator.phase == .idle)
    }

    @Test func cannotImportWhileRecording() async {
        let coordinator = makeCoordinator()
        await coordinator.monitorDevices()
        await coordinator.startRecording()

        #expect(coordinator.isRecording)
        #expect(!coordinator.canImportAudio)
        await coordinator.stopRecording()
    }
}
