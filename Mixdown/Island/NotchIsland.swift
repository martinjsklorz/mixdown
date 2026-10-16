import AppKit
import SwiftUI

/// A Dynamic Island for the Mac: a black panel that grows out of the camera notch while recording,
/// with the time on its left and the input levels on its right.
///
/// macOS has no API for the notch, so this is an ordinary borderless panel above the menu bar,
/// placed over the notch. On a screen without one, it hangs from the top center of the menu bar.
@MainActor
final class NotchIsland {
    enum Side: String, CaseIterable, Identifiable {
        case left
        case right

        var id: Self { self }

        var title: String {
            switch self {
            case .left: "Left of Notch"
            case .right: "Right of Notch"
            }
        }
    }

    /// What the island shows, and where.
    struct Layout: Equatable {
        /// The side of the notch for the recording time. The input levels go on the other side.
        var timeSide: Side = .left
        /// Without levels, the island only reaches out on the time's side.
        var showsLevels = true
    }

    private let environment: AppEnvironment
    private let openRecorder: () -> Void
    /// Created on first `show()`, as windows shouldn't be made before the app has launched.
    private var panel: IslandPanel?
    private(set) var isShown = false
    private var layout = Layout()

    init(environment: AppEnvironment, openRecorder: @escaping () -> Void) {
        self.environment = environment
        self.openRecorder = openRecorder
    }

    /// Shows the island laid out as `layout`, or lays it out again if it's already showing.
    func show(_ layout: Layout) {
        let layoutChanged = layout != self.layout
        self.layout = layout
        if isShown {
            if layoutChanged, let panel { place(panel) }
            return
        }
        isShown = true
        let panel = panel ?? makePanel()
        place(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isShown, let panel else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor [weak self] in
                // Shown again while fading out.
                guard let self, !self.isShown else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    private func makePanel() -> IslandPanel {
        let panel = IslandPanel()
        self.panel = panel
        // Follows displays being connected, rearranged or changing resolution.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.place(panel)
            }
        }
        return panel
    }

    /// Sizes `panel` around the notch of the screen that has one, else the main screen, and gives it
    /// a view laid out for that notch and `layout`.
    private func place(_ panel: IslandPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
        else { return }
        let notch = Self.notch(on: screen)
        let wing = NotchIslandView.wingWidth
        let width = notch.width + (layout.showsLevels ? 2 : 1) * wing
        let x =
            if notch.width == 0 {
                // No notch to grow out of: centered.
                notch.midX - width / 2
            } else if layout.showsLevels || layout.timeSide == .left {
                notch.minX - wing
            } else {
                notch.minX
            }
        let frame = NSRect(x: x, y: notch.minY, width: width, height: notch.height)
        let hostingView = NSHostingView(
            rootView: NotchIslandView(
                environment: environment,
                notchWidth: notch.width,
                layout: layout,
                openRecorder: openRecorder
            )
        )
        // The panel is sized here, not by the view.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.setFrame(frame, display: true)
    }

    /// The notch in screen coordinates. On a screen without one, a zero-width rectangle at the top
    /// center, as tall as the menu bar.
    static func notch(on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
            let left = screen.auxiliaryTopLeftArea,
            let right = screen.auxiliaryTopRightArea
        {
            let height = screen.safeAreaInsets.top
            return NSRect(
                x: frame.minX + left.width,
                y: frame.maxY - height,
                width: frame.width - left.width - right.width,
                height: height
            )
        }
        // Without a menu bar showing (e.g. it hides automatically), visibleFrame reaches the top.
        let menuBarHeight = frame.maxY - screen.visibleFrame.maxY
        let height = menuBarHeight > 0 ? menuBarHeight : NSStatusBar.system.thickness
        return NSRect(x: frame.midX, y: frame.maxY - height, width: 0, height: height)
    }
}

/// A panel that floats over the menu bar on every Space, including full-screen apps, and never
/// takes focus from the app in front.
private final class IslandPanel: NSPanel {
    convenience init() {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        // Panels hide when their app isn't active by default, and Mixdown rarely is while recording.
        hidesOnDeactivate = false
        isMovable = false
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Keeps the panel over the menu bar, where AppKit would otherwise move a window out from.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
