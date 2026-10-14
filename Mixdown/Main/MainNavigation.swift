import AppKit
import Observation
import SwiftUI

/// What the main window shows, and which Settings tab is open. Shared with the menus and the
/// menu bar extra, which open the window at a particular section.
@MainActor @Observable
final class MainNavigation {
    enum Destination: Hashable {
        case recorder
        /// The note at `selectedNoteID`, or the newest one.
        case notes
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case recording = "Recording"
        case transcription = "Transcription"

        var id: Self { self }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .recording: "mic"
            case .transcription: "waveform"
            }
        }
    }

    var destination: Destination = .recorder
    /// Kept while another section is showing, so going back to Notes returns to the same note.
    var selectedNoteID: URL?
    var settingsTab: SettingsTab = .general

    /// Switches to `destination` and brings the main window forward, opening it if it's closed.
    func show(_ destination: Destination, using openWindow: OpenWindowAction) {
        self.destination = destination
        // The app isn't active when the menu bar extra is used.
        NSApp.activate()
        openWindow(id: MainView.windowID)
    }

    /// Opens the Settings window, at `tab` if given.
    func showSettings(_ tab: SettingsTab? = nil, using openSettings: OpenSettingsAction) {
        if let tab { settingsTab = tab }
        // The app isn't active when the menu bar extra is used.
        NSApp.activate()
        openSettings()
    }
}
