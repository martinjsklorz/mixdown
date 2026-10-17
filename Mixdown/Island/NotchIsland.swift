import AppKit
import SwiftUI

/// A Dynamic Island for the Mac: a black panel that grows out of the camera notch while recording,
/// with the time on one side and the input levels on the other, each only as wide as it needs to be
/// so it hides as little of the menu bar as it can.
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
    /// The time's wing as wide as the view last measured it, which grows with the time.
    private var timeWingWidth: CGFloat = 56

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
                guard let self, !self.isShown, let panel = self.panel else { return }
                panel.orderOut(nil)
                // Ends the view's clock and level sampling, which an ordered-out window keeps
                // running. `place(_:)` makes a new view on the next `show(_:)`.
                panel.contentView = nil
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
                guard let self, self.isShown, let panel = self.panel else { return }
                self.place(panel)
            }
        }
        return panel
    }

    /// The screen that has a notch, else the main screen.
    private static var screen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
    }

    /// Gives `panel` a view laid out for the notch and `layout`, and sizes it around the notch.
    private func place(_ panel: IslandPanel) {
        guard let screen = Self.screen else { return }
        let notch = Self.notch(on: screen)
        let hostingView = NSHostingView(
            rootView: NotchIslandView(
                environment: environment,
                notchWidth: notch.width,
                layout: layout,
                openRecorder: openRecorder,
                timeWingWidthChanged: { [weak self] width in self?.timeWingWidthChanged(width) }
            )
        )
        // The panel is sized here, not by the view.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        // Over full-screen apps only beside a notch, where they leave the menu bar black. Without
        // one, the island would cover the app.
        if notch.width > 0 {
            panel.collectionBehavior.insert(.fullScreenAuxiliary)
        } else {
            panel.collectionBehavior.remove(.fullScreenAuxiliary)
        }
        panel.setFrame(frame(around: notch), display: true)
    }

    /// The island's frame: the wings, each as wide as its content, either side of `notch`.
    private func frame(around notch: NSRect) -> NSRect {
        let levelsWidth = layout.showsLevels ? NotchIslandView.levelsWingWidth : 0
        let (left, right) =
            layout.timeSide == .left ? (timeWingWidth, levelsWidth) : (levelsWidth, timeWingWidth)
        let width = left + notch.width + right
        // Without a notch to grow out of: centered.
        let x = notch.width == 0 ? notch.midX - width / 2 : notch.minX - left
        return NSRect(x: x, y: notch.minY, width: width, height: notch.height)
    }

    /// Widens or narrows the island as the time gets longer, such as from "9:59" to "10:00".
    private func timeWingWidthChanged(_ width: CGFloat) {
        guard abs(width - timeWingWidth) >= 0.5 else { return }
        timeWingWidth = width
        guard isShown, let panel, let screen = Self.screen else { return }
        panel.setFrame(frame(around: Self.notch(on: screen)), display: true)
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

/// A panel that floats over the menu bar on every Space, and never takes focus from the app in
/// front. `NotchIsland` decides whether it also shows over full-screen apps.
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
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Keeps the panel over the menu bar, where AppKit would otherwise move a window out from.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
