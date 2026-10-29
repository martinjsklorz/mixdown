import Foundation
import MixdownCore
import Testing

struct URLCommandTests {
    private func command(_ string: String) -> URLCommand? {
        URL(string: string).flatMap(URLCommand.init(url:))
    }

    @Test func readsRecordingActions() {
        #expect(command("mixdown://toggle") == .toggleRecording)
        #expect(command("mixdown://start") == .startRecording)
        #expect(command("mixdown://stop") == .stopRecording)
        #expect(command("mixdown://pause") == .pauseRecording)
        #expect(command("mixdown://resume") == .resumeRecording)
        #expect(command("mixdown://toggle-pause") == .togglePause)
    }

    @Test func ignoresCaseSlashesAndTheMissingAuthority() {
        #expect(command("MIXDOWN://Toggle") == .toggleRecording)
        #expect(command("mixdown://toggle/") == .toggleRecording)
        #expect(command("mixdown:toggle") == .toggleRecording)
        #expect(command("mixdown:///stop") == .stopRecording)
    }

    @Test func marksMomentsWithOrWithoutText() {
        #expect(command("mixdown://mark") == .markMoment(text: nil))
        #expect(command("mixdown://mark?text=Action%20item") == .markMoment(text: "Action item"))
        #expect(command("mixdown://mark?text=Budget+%26+dates") == .markMoment(text: "Budget+&+dates"))
        #expect(command("mixdown://mark?text=%20%20") == .markMoment(text: nil))
        #expect(command("mixdown://mark?text=") == .markMoment(text: nil))
    }

    @Test func opensTheWindowOrANote() {
        #expect(command("mixdown://open") == .open(note: nil))
        #expect(command("mixdown://open?note=latest") == .open(note: "latest"))
        #expect(
            command("mixdown://open?note=Clients/Acme/Weekly%20Sync.md") == .open(note: "Clients/Acme/Weekly Sync.md")
        )
        #expect(command("mixdown://open?NOTE=Standup") == .open(note: "Standup"))
    }

    @Test(arguments: [
        URLCommand.toggleRecording, .startRecording, .stopRecording, .pauseRecording, .resumeRecording, .togglePause,
        .markMoment(text: nil), .markMoment(text: "Budget & dates = 50% + tax #1"), .markMoment(text: "Größe?/ok"),
        .open(note: nil), .open(note: "latest"), .open(note: "Clients/Acme/2026-10-24 0930 Weekly Sync.md"),
    ])
    func makesLinksThatReadBack(_ command: URLCommand) {
        #expect(command.url.scheme == "mixdown")
        #expect(URLCommand(url: command.url) == command)
    }

    @Test func makesReadableLinks() {
        #expect(URLCommand.togglePause.url.absoluteString == "mixdown://toggle-pause")
        #expect(URLCommand.open(note: "Weekly Sync").url.absoluteString == "mixdown://open?note=Weekly%20Sync")
    }

    @Test func rejectsOtherLinks() {
        #expect(command("https://toggle") == nil)
        #expect(command("mixdown://") == nil)
        #expect(command("mixdown://record") == nil)
        #expect(command("other://toggle") == nil)
    }
}
