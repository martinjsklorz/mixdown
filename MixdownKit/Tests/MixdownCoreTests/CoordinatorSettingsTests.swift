import Foundation
import Testing

@testable import MixdownCore

/// How the user's settings become what the coordinator does.
@MainActor
struct CoordinatorSettingsTests {
    private let summarizer = MockSummarizer()
    private let diarizer = MockDiarizer()

    private func makeCoordinator(capture: MockCapture = MockCapture()) -> RecordingCoordinator {
        RecordingCoordinator(
            deviceProvider: MockDeviceProvider(devices: Fixtures.devices),
            captureFactory: MockCaptureFactory(capture: capture),
            engine: MockEngine(),
            noteWriter: InMemoryNoteWriter(),
            now: { Fixtures.startDate }
        )
    }

    @Test func copiesTheSimpleSettings() {
        let coordinator = makeCoordinator()
        let labels = SourceLabels(microphone: "Anna", systemAudio: "Team")
        coordinator.apply(
            CoordinatorSettings(
                language: "de",
                sourceLabels: labels,
                cancelsEcho: false,
                measuresTalkTime: true,
                keepsAudioOnDisk: false,
                translatesLiveText: false
            ),
            summarizer: summarizer,
            diarizer: diarizer
        )
        #expect(coordinator.options.language == "de")
        #expect(coordinator.sourceLabels == labels)
        #expect(!coordinator.cancelsEcho)
        #expect(coordinator.measuresTalkTime)
        #expect(!coordinator.keepsAudioOnDisk)
        #expect(!coordinator.translatesLiveText)
    }

    @Test func zeroMinutesNeverAsksIfStillRecording() {
        let coordinator = makeCoordinator()
        coordinator.apply(CoordinatorSettings(stillRecordingMinutes: 0), summarizer: nil, diarizer: nil)
        #expect(coordinator.stillRecordingDelay == nil)
        coordinator.apply(CoordinatorSettings(stillRecordingMinutes: 15), summarizer: nil, diarizer: nil)
        #expect(coordinator.stillRecordingDelay == .seconds(15 * 60))
    }

    @Test func namingSpeakersNeedsTellingThemApartToo() {
        let coordinator = makeCoordinator()
        coordinator.apply(
            CoordinatorSettings(identifiesSpeakers: false, namesSpeakers: true),
            summarizer: summarizer,
            diarizer: diarizer
        )
        #expect(coordinator.speakerDiarizer == nil)
        #expect(coordinator.speakerNamer == nil)

        coordinator.apply(
            CoordinatorSettings(identifiesSpeakers: true, namesSpeakers: false),
            summarizer: summarizer,
            diarizer: diarizer
        )
        #expect(coordinator.speakerDiarizer != nil)
        #expect(coordinator.speakerNamer == nil)

        coordinator.apply(
            CoordinatorSettings(identifiesSpeakers: true, namesSpeakers: true),
            summarizer: summarizer,
            diarizer: diarizer
        )
        #expect(coordinator.speakerNamer != nil)
    }

    @Test func summariesAndTranslationFollowTheirToggles() {
        let coordinator = makeCoordinator()
        coordinator.apply(
            CoordinatorSettings(summarizesNotes: false, translatesNotes: false, translationLanguage: "fr"),
            summarizer: summarizer,
            diarizer: nil
        )
        #expect(coordinator.summarizer == nil)
        #expect(coordinator.translationLanguage == nil)

        coordinator.apply(
            CoordinatorSettings(summarizesNotes: true, translatesNotes: true, translationLanguage: "fr"),
            summarizer: summarizer,
            diarizer: nil
        )
        #expect(coordinator.summarizer != nil)
        #expect(coordinator.translationLanguage == "fr")
    }

    @Test func noteTitlesFollowTheirToggle() {
        let coordinator = makeCoordinator()
        #expect(coordinator.titlesNotesFromSummary)
        coordinator.apply(CoordinatorSettings(titlesNotesFromSummary: false), summarizer: summarizer, diarizer: nil)
        #expect(!coordinator.titlesNotesFromSummary)
        coordinator.apply(CoordinatorSettings(titlesNotesFromSummary: true), summarizer: summarizer, diarizer: nil)
        #expect(coordinator.titlesNotesFromSummary)
    }

    @Test func picksTheTemplatesForRecordingsAndCalls() {
        let coordinator = makeCoordinator()
        let templates = SummaryTemplateLibrary(recordingTemplateID: "standup", callTemplateID: "general")
        coordinator.apply(CoordinatorSettings(summaryTemplates: templates), summarizer: nil, diarizer: nil)
        #expect(coordinator.summaryTemplate.id == "standup")
        #expect(coordinator.callSummaryTemplate.id == "general")
    }

    @Test func anEditedTemplateReachesTheRecordingInProgress() async throws {
        let coordinator = makeCoordinator(capture: MockCapture(chunks: [Fixtures.chunk(seconds: 1)]))
        await coordinator.monitorDevices()
        await coordinator.startRecording()
        #expect(coordinator.recordingSummaryTemplate?.id == "general")

        let edited = SummaryTemplate(id: "general", name: "General", instructions: "Look out for dates.")
        coordinator.apply(
            CoordinatorSettings(summaryTemplates: SummaryTemplateLibrary(stored: [edited])),
            summarizer: nil,
            diarizer: nil
        )
        #expect(coordinator.recordingSummaryTemplate == edited)
        await coordinator.stopRecording()
    }
}
