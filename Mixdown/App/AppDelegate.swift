import AppKit
import SwiftUI

/// Brings the main window back when the Dock icon is clicked. SwiftUI does that for a
/// `WindowGroup`, but not for a `Window` that has been closed. Also adds help topics to the Help
/// menu's search, and asks before quitting with notes that haven't been saved.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `capturesOpenWindow(for:navigation:environment:)`, which also gives it SwiftUI's
    /// `openWindow`.
    fileprivate weak var navigation: MainNavigation?
    fileprivate weak var environment: AppEnvironment?
    private var helpSearch: HelpSearch?

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

    /// Notes waiting for the notes folder only live in memory, so quitting would lose them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let count = environment?.coordinator.pendingNotes.count ?? 0
        guard count > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1 ? "A note hasn't been saved yet" : "\(count) notes haven't been saved yet"
        alert.informativeText =
            "Mixdown couldn't reach the notes folder. If you quit now, "
            + (count == 1 ? "the note is" : "the notes are")
            + " lost. Connect the folder's drive, or choose another folder in Settings, and Mixdown "
            + "saves " + (count == 1 ? "it." : "them.")
        alert.addButton(withTitle: "Don't Quit")
        let quit = alert.addButton(withTitle: "Quit Anyway")
        quit.hasDestructiveAction = true
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
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
        }
    }
}
