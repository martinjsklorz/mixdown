import SwiftUI

/// Turns launching Mixdown at login on or off, with what macOS says about it. Shared by Settings
/// and the setup assistant.
struct LaunchAtLoginToggle: View {
    @State private var launchAtLogin = LaunchAtLogin()

    var body: some View {
        Toggle(
            "Launch Mixdown at login",
            isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            )
        )
        // The user can change it in System Settings › General › Login Items, so re-read on
        // showing it, and whenever a window of ours comes back to the front: on reopening Settings
        // (which keeps its tabs alive) and on returning from System Settings.
        .onAppear { launchAtLogin.refresh() }
        .onWindowBecomesKey { launchAtLogin.refresh() }
        if launchAtLogin.requiresApproval {
            Caption("Allow Mixdown in System Settings › General › Login Items.")
        }
        if let error = launchAtLogin.errorMessage {
            Caption(error, isWarning: true)
        }
    }
}
