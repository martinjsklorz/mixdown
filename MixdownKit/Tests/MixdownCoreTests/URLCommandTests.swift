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

    @Test func rejectsOtherLinks() {
        #expect(command("https://toggle") == nil)
        #expect(command("mixdown://") == nil)
        #expect(command("mixdown://record") == nil)
        #expect(command("other://toggle") == nil)
    }
}
