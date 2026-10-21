import AppKit
import Observation
import SwiftUI

/// What the main window shows, and which Settings tab and Help topic are open. Shared with the
/// menus and the menu bar extra, which open the window at a particular section.
@MainActor @Observable
final class MainNavigation {
    enum Destination: Hashable {
        case recorder
        /// The note at `selectedNoteID`, or the newest one.
        case notes
    }

    /// A block of a note, by its index in `NoteDocument.displayBlocks()`.
    struct NoteBlock: Equatable {
        var noteID: URL
        var index: Int
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case recording = "Recording"
        case transcription = "Transcription"
        case vocabulary = "Vocabulary"
        case notifications = "Notifications"
        case design = "Design"

        var id: Self { self }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .recording: "mic"
            case .transcription: "waveform"
            case .vocabulary: "character.book.closed"
            case .notifications: "bell.badge"
            case .design: "paintbrush"
            }
        }
    }

    var destination: Destination = .recorder
    /// Kept while another section is showing, so going back to Notes returns to the same note.
    var selectedNoteID: URL?
    /// A note to select once the main window has loaded the notes folder, e.g. one opened from
    /// its notification. The window clears it when it takes it.
    var noteToShow: URL?
    /// The line of `noteToShow` to scroll to, by its number in `NoteSearchIndex.lines(of:)`: the
    /// one picked in Spotlight. Taken with it.
    private var noteLineToShow: Int?
    /// A block of a note for its view to scroll to and highlight. The view clears it when it
    /// takes it.
    var blockToShow: NoteBlock?
    var settingsTab: SettingsTab = .general
    /// Whether the main window shows the setup assistant. Set at launch until it's been through
    /// once, and by Help › Setup Assistant….
    var isShowingSetup = false
    var helpTopic: HelpTopic = .gettingStarted
    /// What the Help window's sidebar is filtered by.
    var helpSearchText = ""

    /// SwiftUI only hands `openWindow` to views, so `capturesOpenWindow(for:navigation:environment:)`
    /// stores it here for the Dock icon and notifications. The main window opens at launch, so it's
    /// set early on.
    @ObservationIgnored var openWindow: OpenWindowAction?

    /// Switches to `destination` and brings the main window forward, opening it if it's closed.
    func show(_ destination: Destination, using openWindow: OpenWindowAction) {
        self.destination = destination
        // The app isn't active when the menu bar extra is used.
        NSApp.activate()
        openWindow(id: MainView.windowID)
    }

    /// Selects the note at `url` and brings the main window forward, opening it if it's closed.
    /// With a `line` (see `noteLineToShow`), scrolls to it.
    func showNote(at url: URL, line: Int? = nil) {
        noteLineToShow = line
        noteToShow = url
        destination = .notes
        NSApp.activate()
        openWindow?(id: MainView.windowID)
    }

    /// Takes `noteToShow` and its line, clearing them.
    func takeNoteToShow() -> (url: URL, line: Int?)? {
        defer {
            noteToShow = nil
            noteLineToShow = nil
        }
        return noteToShow.map { ($0, noteLineToShow) }
    }

    /// Brings the main window forward with the setup assistant over it.
    func showSetup(using openWindow: OpenWindowAction) {
        isShowingSetup = true
        show(.recorder, using: openWindow)
    }

    /// Opens the Settings window, at `tab` if given.
    func showSettings(_ tab: SettingsTab? = nil, using openSettings: OpenSettingsAction) {
        if let tab { settingsTab = tab }
        // The app isn't active when the menu bar extra is used.
        NSApp.activate()
        openSettings()
    }

    /// Opens the Help window at `topic` if given. With `search`, filters its topics by it and
    /// shows the first match.
    func showHelp(
        _ topic: HelpTopic? = nil,
        searching search: String? = nil,
        using openWindow: OpenWindowAction? = nil
    ) {
        if let search {
            helpSearchText = search
            if let match = HelpTopic.search(search).first { helpTopic = match }
        }
        if let topic {
            helpTopic = topic
            // Keep it in the sidebar.
            if !HelpTopic.search(helpSearchText).contains(topic) { helpSearchText = "" }
        }
        NSApp.activate()
        (openWindow ?? self.openWindow)?(id: HelpView.windowID)
    }
}
