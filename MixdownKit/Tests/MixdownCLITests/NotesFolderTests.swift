import Foundation
import Testing

@testable import MixdownCLI

struct NotesFolderTests {
    private let home = FileManager.default.temporaryDirectory.appending(
        path: "MixdownCLIHome-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )

    @Test func prefersTheOptionThenTheEnvironment() throws {
        let environment = [NotesFolder.environmentVariable: "/Volumes/Notes"]
        #expect(try NotesFolder.url(option: "/tmp/Notes", environment: environment, home: home).path == "/tmp/Notes")
        #expect(try NotesFolder.url(option: nil, environment: environment, home: home).path == "/Volumes/Notes")
        let tilde = try NotesFolder.url(option: "~/Notes", environment: [:], home: home)
        #expect(!tilde.path.hasPrefix("~"))
    }

    @Test func saysWhenMixdownHasNoFolder() throws {
        #expect(throws: FolderError.notChosen) {
            try NotesFolder.url(option: nil, environment: [NotesFolder.environmentVariable: ""], home: home)
        }

        // Settings without the folder, as before choosing one.
        let preferences = NotesFolder.preferencesFile(home: home)
        try FileManager.default.createDirectory(
            at: preferences.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["playsSounds": true],
            format: .binary,
            options: 0
        )
        try plist.write(to: preferences)
        #expect(throws: FolderError.notChosen) { try NotesFolder.url(option: nil, environment: [:], home: home) }
    }

    @Test func readsTheAppsSettingsInItsContainer() {
        #expect(
            NotesFolder.preferencesFile(home: URL(filePath: "/Users/me", directoryHint: .isDirectory)).path
                == "/Users/me/Library/Containers/app.mixdown.Mixdown/Data/Library/Preferences/app.mixdown.Mixdown.plist"
        )
    }
}
