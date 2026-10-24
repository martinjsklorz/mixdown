import SwiftUI

/// The setup assistant's page for where a recording's audio is kept until its note is saved.
struct AudioPage: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let preferences = environment.preferences

        SetupPage(
            title: "Keeping Your Audio",
            systemImage: "externaldrive",
            detail: "Mixdown keeps a recording's audio only until its note is saved, then deletes it. "
                + "Choose where it's kept until then."
        ) {
            Form {
                Section {
                    SetupChoice(
                        title: "On Disk",
                        systemImage: "lock.doc",
                        detail: "Written to Mixdown's own folder as you record. Quitting, a crash or a "
                            + "failed transcription doesn't lose the recording.",
                        isSelected: preferences.keepsAudioOnDisk
                    ) {
                        preferences.keepsAudioOnDisk = true
                    }
                    SetupChoice(
                        title: "In Memory Only",
                        systemImage: "memorychip",
                        detail: "No audio ever touches the disk. A failed transcription can be tried "
                            + "again until Mixdown quits, but a crash loses the recording.",
                        isSelected: !preferences.keepsAudioOnDisk
                    ) {
                        preferences.keepsAudioOnDisk = false
                    }
                } footer: {
                    Caption(
                        "Either way, your audio never leaves this Mac. Change it any time under "
                            + "Settings → Recording."
                    )
                }
            }
            .formStyle(.grouped)
        }
    }
}
