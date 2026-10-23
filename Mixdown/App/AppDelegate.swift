import AppKit
import CoreSpotlight
import MixdownCore
import MixdownNotes
import SwiftUI

/// Brings the main window back when the Dock icon is clicked. SwiftUI does that for a
/// `WindowGroup`, but not for a `Window` that has been closed. Also adds help topics to the Help
/// menu's search, opens notes picked in Spotlight, and asks before quitting would lose a recording
/// or a note.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `capturesOpenWindow(for:navigation:environment:)`, which also gives it SwiftUI's
    /// `openWindow`.
    fileprivate weak var navigation: MainNavigation?
    fileprivate weak var environment: AppEnvironment?
    private var helpSearch: HelpSearch?
    /// A note picked in Spotlight before `navigation` was set, at launch.
    private var pendingSpotlightItem: (url: URL, line: Int?)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before the first window appears, so it doesn't flash in the system's appearance.
        AppSettings().appearance.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let helpSearch = HelpSearch { [weak self] topic, search in
            self?.navigation?.showHelp(topic, searching: search)
        }
        NSApp.registerUserInterfaceItemSearchHandler(helpSearch)
        self.helpSearch = helpSearch
    }

    /// A recording, one being made into a note and notes waiting for the notes folder only live
    /// in memory, so quitting would lose them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator = environment?.coordinator else { return .terminateNow }
        for warning in [inProgressWarning(coordinator), unsavedNotesWarning(coordinator)] {
            guard let warning else { continue }
            guard confirmQuit(warning) else { return .terminateCancel }
        }
        return .terminateNow
    }

    private struct QuitWarning {
        let message: String
        let information: String
    }

    private func inProgressWarning(_ coordinator: RecordingCoordinator) -> QuitWarning? {
        if coordinator.isRecording {
            return QuitWarning(
                message: "Mixdown is recording",
                information: "If you quit now, the recording is lost. Stop it first, and Mixdown makes it into a note."
            )
        }
        guard coordinator.isMakingNote else { return nil }
        if let name = coordinator.importingFileName {
            return QuitWarning(
                message: "Mixdown is still importing “\(name)”",
                information: "If you quit now, no note is saved. You can import the file again later."
            )
        }
        return QuitWarning(
            message: "Mixdown is still making a note of the recording",
            information: "If you quit now, the recording is lost. Wait until the note is saved."
        )
    }

    private func unsavedNotesWarning(_ coordinator: RecordingCoordinator) -> QuitWarning? {
        let count = coordinator.pendingNotes.count
        guard count > 0 else { return nil }
        return QuitWarning(
            message: count == 1 ? "A note hasn't been saved yet" : "\(count) notes haven't been saved yet",
            information: "Mixdown couldn't reach the notes folder. If you quit now, "
                + (count == 1 ? "the note is" : "the notes are")
                + " lost. Connect the folder's drive, or choose another folder in Settings, and Mixdown "
                + "saves " + (count == 1 ? "it." : "them.")
        )
    }

    /// Whether the user chose to quit anyway.
    private func confirmQuit(_ warning: QuitWarning) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warning.message
        alert.informativeText = warning.information
        alert.addButton(withTitle: "Don't Quit")
        let quit = alert.addButton(withTitle: "Quit Anyway")
        quit.hasDestructiveAction = true
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Opens the note, at the line, picked in Spotlight. See `NoteSpotlight`.
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
            let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
            let location = NoteSearchIndex.location(ofItemID: id)
        else { return false }
        pendingSpotlightItem = (location.noteURL, location.line)
        showPendingSpotlightItem()
        return true
    }

    fileprivate func showPendingSpotlightItem() {
        guard let navigation, let item = pendingSpotlightItem else { return }
        pendingSpotlightItem = nil
        navigation.showNote(at: item.url, line: item.line)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Regardless of `flag`: the menu bar extra's window can count as visible.
        navigation?.openWindow?(id: MainView.windowID)
        return false
    }
}

extension View {
    /// Lets `delegate` and `navigation` open windows once this view has appeared, and gives
    /// `delegate` the environment.
    func capturesOpenWindow(
        for delegate: AppDelegate,
        navigation: MainNavigation,
        environment: AppEnvironment
    ) -> some View {
        modifier(OpenWindowCapture(delegate: delegate, navigation: navigation, environment: environment))
    }
}

private struct OpenWindowCapture: ViewModifier {
    let delegate: AppDelegate
    let navigation: MainNavigation
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            navigation.openWindow = openWindow
            delegate.navigation = navigation
            delegate.environment = environment
            delegate.showPendingSpotlightItem()
        }
    }
}
