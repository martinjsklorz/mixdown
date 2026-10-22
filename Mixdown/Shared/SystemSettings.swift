import AppKit

/// Opens System Settings at the pane for something Mixdown needs from the user.
enum SystemSettings {
    enum Pane {
        /// Privacy & Security › Microphone.
        case microphone
        /// Privacy & Security › Screen & System Audio Recording, which holds the "System Audio
        /// Recording Only" list.
        case screenAndSystemAudioRecording
        /// Notifications, at Mixdown.
        case notifications

        var url: URL? {
            switch self {
            case .microphone:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .screenAndSystemAudioRecording:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            case .notifications:
                Bundle.main.bundleIdentifier.flatMap { bundleID in
                    URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")
                }
            }
        }
    }

    static func open(_ pane: Pane) {
        guard let url = pane.url else { return }
        NSWorkspace.shared.open(url)
    }
}
