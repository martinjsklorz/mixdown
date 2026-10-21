import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Starts and stops recording from any app. Changed or turned off under Settings → General.
    /// ⌃⌥⌘R rather than ⌥⌘R, which Safari and Xcode already use.
    static let toggleRecording = Self(
        "toggleRecording",
        initial: .init(.r, modifiers: [.control, .option, .command])
    )
}

extension KeyboardShortcuts.Name {
    /// Marks a moment in the recording from any app, and opens a field under the notch to write a
    /// few words about it. Only taken while recording. Changed or cleared under Settings → General.
    static let markMoment = Self(
        "markMoment",
        initial: .init(.m, modifiers: [.control, .option, .command])
    )
}

extension View {
    /// Shows the global Start/Stop Recording shortcut on a menu bar menu item while `isGlobal`, as
    /// that's the one that works with the menu closed, else ⌘R.
    @ViewBuilder
    func recordingShortcut(isGlobal: Bool) -> some View {
        if isGlobal, KeyboardShortcuts.getShortcut(for: .toggleRecording) != nil {
            globalKeyboardShortcut(.toggleRecording)
        } else {
            keyboardShortcut("r")
        }
    }
}
