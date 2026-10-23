import Foundation
import Testing

@testable import MixdownCore

struct SummaryTemplateLibraryTests {
    @Test func startsWithTheBuiltInsAndGeneralForEveryRecording() {
        let library = SummaryTemplateLibrary()

        #expect(library.templates == SummaryTemplate.builtIns)
        #expect(library.recordingTemplate == .general)
        #expect(library.callTemplate == .general)
        #expect(library.changedTemplates.isEmpty)
    }

    @Test func recordingTemplatesFollowEdits() {
        var library = SummaryTemplateLibrary(recordingTemplateID: "standup", callTemplateID: "clientCall")
        var standup = SummaryTemplate.standup
        standup.name = "Daily"
        library.update(standup)

        #expect(library.recordingTemplate.name == "Daily")
        #expect(library.callTemplate == .clientCall)
        #expect(library.changedTemplates == [standup])
    }

    @Test func updatesCutLongInstructionsAndIgnoreUnknownTemplates() {
        var library = SummaryTemplateLibrary()
        var general = SummaryTemplate.general
        general.instructions = String(repeating: "a", count: SummaryTemplate.maximumInstructionsLength + 10)
        library.update(general)
        library.update(SummaryTemplate(id: "custom-1", name: "Review"))

        #expect(library.templates[0].instructions.count == SummaryTemplate.maximumInstructionsLength)
        #expect(library.templates.count == SummaryTemplate.builtIns.count)
    }

    @Test func addsCopiesAndBlankTemplates() {
        var library = SummaryTemplateLibrary()
        let blank = library.add()
        let copy = library.add(copying: .standup)

        #expect(blank.name == "New Template")
        #expect(copy.name == "Standup Copy")
        #expect(library.templates.suffix(2) == [blank, copy])
        #expect(library.changedTemplates == [blank, copy])
    }

    @Test func deletingATemplateInUseFallsBackToGeneral() {
        var library = SummaryTemplateLibrary()
        let review = library.add()
        library.recordingTemplate = review
        library.callTemplate = review
        library.delete(id: review.id)

        #expect(!library.templates.contains(review))
        #expect(library.recordingTemplateID == SummaryTemplate.general.id)
        #expect(library.callTemplateID == SummaryTemplate.general.id)
    }

    @Test func builtInsCanOnlyBeRestored() {
        var library = SummaryTemplateLibrary(recordingTemplateID: "oneOnOne")
        var oneOnOne = SummaryTemplate.oneOnOne
        oneOnOne.layout = .overview
        library.update(oneOnOne)
        library.delete(id: "oneOnOne")

        #expect(library.recordingTemplate == oneOnOne)
        library.restore(id: "oneOnOne")
        #expect(library.recordingTemplate == .oneOnOne)
        #expect(library.changedTemplates.isEmpty)
    }

    @Test func missingTemplatesResolveToGeneral() {
        let library = SummaryTemplateLibrary(
            stored: [SummaryTemplate(id: "custom-1", name: "Review")],
            recordingTemplateID: "custom-2",
            callTemplateID: "custom-1"
        )

        #expect(library.recordingTemplate == .general)
        #expect(library.callTemplate.name == "Review")
    }
}
