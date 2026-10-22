import SwiftUI

/// The setup assistant's page for the global recording shortcut and launching at login.
struct ShortcutsPage: View {
    var body: some View {
        SetupPage(
            title: "Always at Hand",
            systemImage: "keyboard",
            detail: "Mixdown lives in the menu bar. Start and stop recording from any app with a "
                + "shortcut, without switching to Mixdown."
        ) {
            Form {
                Section {
                    RecordingShortcutToggle()
                } footer: {
                    Caption("Click the shortcut and press new keys to change it.")
                }

                Section {
                    LaunchAtLoginToggle()
                } footer: {
                    Caption("Keeps Mixdown in the menu bar, ready for calls, after you restart your Mac.")
                }
            }
            .formStyle(.grouped)
        }
    }
}
