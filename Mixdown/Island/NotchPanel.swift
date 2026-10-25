import AppKit

/// A borderless panel by the notch, for the Dynamic Island and what drops down under it. It floats
/// over the menu bar on every Space and doesn't activate Mixdown, which rarely is in front while
/// recording. It's left out of screen sharing and screenshots, so the others on a call don't see
/// the live text, a Catch Me Up summary or a moment being typed when the screen is shared.
final class NotchPanel: NSPanel {
    private var allowsKey = false

    /// - Parameters:
    ///   - canBecomeKey: Whether it can take the keyboard, for a field. Otherwise it never takes
    ///     focus from the app in front.
    ///   - showsOverFullScreenApps: Whether it also shows over full-screen apps. Can be changed
    ///     later through `collectionBehavior`.
    ///   - isDark: Whether it's always in Dark Mode, e.g. for light text and caret on black.
    convenience init(canBecomeKey: Bool = false, showsOverFullScreenApps: Bool, isDark: Bool) {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        allowsKey = canBecomeKey
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        // Panels hide when their app isn't active by default.
        hidesOnDeactivate = false
        isMovable = false
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
        sharingType = .none
        if canBecomeKey {
            // Takes the keyboard as soon as it's made key, not only for controls that need it.
            becomesKeyOnlyIfNeeded = false
        }
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if showsOverFullScreenApps {
            collectionBehavior.insert(.fullScreenAuxiliary)
        }
        if isDark {
            appearance = NSAppearance(named: .darkAqua)
        }
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Keeps the panel up by the menu bar, where AppKit would otherwise move a window out from.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
