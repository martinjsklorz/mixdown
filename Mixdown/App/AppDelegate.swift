import AppKit
import SwiftUI

/// Brings the main window back when the Dock icon is clicked. SwiftUI does that for a
/// `WindowGroup`, but not for a `Window` that has been closed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI only hands `openWindow` to views, so `capturesOpenWindow(for:)` stores it here.
    fileprivate var openWindow: OpenWindowAction?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Regardless of `flag`: the menu bar extra's window can count as visible.
        openWindow?(id: MainView.windowID)
        return false
    }
}

extension View {
    /// Lets `delegate` open windows once this view has appeared.
    func capturesOpenWindow(for delegate: AppDelegate) -> some View {
        modifier(OpenWindowCapture(delegate: delegate))
    }
}

private struct OpenWindowCapture: ViewModifier {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { delegate.openWindow = openWindow }
    }
}
