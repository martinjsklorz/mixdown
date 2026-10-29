import KeyboardShortcuts
import SwiftUI

/// Turns the global Start/Stop Recording shortcut on or off, and records a new one while it's on.
/// Shared by Settings and the setup assistant.
struct RecordingShortcutToggle: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Toggle(
            "Start and stop recording from any app",
            isOn: Bindable(environment.preferences).isRecordingShortcutEnabled
        )
        // Hidden rather than disabled: the recorder is an AppKit field that ignores SwiftUI's
        // `disabled`.
        if environment.preferences.isRecordingShortcutEnabled {
            KeyboardShortcuts.Recorder("Shortcut", name: .toggleRecording)
        }
    }
}
