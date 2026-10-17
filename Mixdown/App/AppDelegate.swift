import AppKit
import SwiftUI

/// Brings the main window back when the Dock icon is clicked. SwiftUI does that for a
/// `WindowGroup`, but not for a `Window` that has been closed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `capturesOpenWindow(for:navigation:)`, which also gives it SwiftUI's `openWindow`.
    fileprivate weak var navigation: MainNavigation?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before the first window appears, so it doesn't flash in the system's appearance.
        AppSettings().appearance.apply()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Regardless of `flag`: the menu bar extra's window can count as visible.
        navigation?.openWindow?(id: MainView.windowID)
        return false
    }
}

extension View {
    /// Lets `delegate` and `navigation` open windows once this view has appeared.
    func capturesOpenWindow(for delegate: AppDelegate, navigation: MainNavigation) -> some View {
        modifier(OpenWindowCapture(delegate: delegate, navigation: navigation))
    }
}

private struct OpenWindowCapture: ViewModifier {
    let delegate: AppDelegate
    let navigation: MainNavigation
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            navigation.openWindow = openWindow
            delegate.navigation = navigation
        }
    }
}
