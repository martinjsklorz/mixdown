import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Starts and stops recording from any app. Changed or turned off under Settings → Recording.
    /// ⌃⌥⌘R rather than ⌥⌘R, which Safari and Xcode already use.
    static let toggleRecording = Self(
        "toggleRecording",
        initial: .init(.r, modifiers: [.control, .option, .command])
    )
}
