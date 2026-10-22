import AppKit
import SwiftUI

/// A Dynamic Island for the Mac: a black panel that grows out of the camera notch while recording,
/// with the time on one side and the input levels on the other, each only as wide as it needs to be
/// so it hides as little of the menu bar as it can. Optionally, the latest words recognized scroll
/// by in a line under the notch.
///
/// macOS has no API for the notch, so this is an ordinary borderless panel above the menu bar,
/// placed over the notch. On a screen without one, it hangs from the top center of the menu bar.
@MainActor
final class DynamicIsland {
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
        /// Whether the latest words scroll by in a line under the notch. Only while the recording
        /// is transcribed live; `AppEnvironment` turns it off otherwise.
        var showsLiveText = false
        /// Whether a ring next to the time shows how the talking is shared between the user and the
        /// others. Only while recording both a microphone and system audio.
        var showsTalkShare = true
    }

    /// Whether the wings are out. They grow out of the notch on `show(_:)` and back into it on
    /// `hide()`, while the panel keeps its full size.
    @MainActor @Observable
    final class Presence {
        var isExpanded = false
    }

    private static let expandAnimation = Animation.smooth(duration: 0.35)
    private static let collapseAnimation = Animation.smooth(duration: 0.3)

    private let environment: AppEnvironment
    private let openRecorder: () -> Void
    /// Told whether the island is the only place the time needs to be; see `showsTimeAlone`.
    private let showsTimeAloneChanged: (Bool) -> Void
    /// Created on the first `show(_:)`, as windows shouldn't be made before the app has launched.
    private var panel: NotchPanel?
    private var isShown = false
    private var layout = Layout()
    private let presence = Presence()
    /// The time's wing as wide as the view last measured it, which grows with the time.
    private var timeWingWidth: CGFloat = 56

    init(
        environment: AppEnvironment,
        openRecorder: @escaping () -> Void,
        showsTimeAloneChanged: @escaping (Bool) -> Void
    ) {
        self.environment = environment
        self.openRecorder = openRecorder
        self.showsTimeAloneChanged = showsTimeAloneChanged
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
        // Still on screen if shown again while collapsing, where the wings grow back out from there.
        if !panel.isVisible || layoutChanged { place(panel) }
        showsTimeAloneChanged(Self.showsTimeAlone)
        panel.orderFrontRegardless()
        // On the next turn of the run loop, after the view has been drawn collapsed.
        Task { @MainActor [weak self] in
            // Hidden again in the meantime.
            guard let self, self.isShown else { return }
            withAnimation(Self.expandAnimation) { self.presence.isExpanded = true }
        }
    }

    func hide() {
        guard isShown, panel != nil else { return }
        isShown = false
        showsTimeAloneChanged(false)
        withAnimation(Self.collapseAnimation) {
            presence.isExpanded = false
        } completion: { [weak self] in
            Task { @MainActor [weak self] in
                // Shown again while collapsing.
                guard let self, !self.isShown, let panel = self.panel else { return }
                panel.orderOut(nil)
                // Ends the view's clock and level sampling, which an ordered-out window keeps
                // running. `place(_:)` makes a new view on the next `show(_:)`.
                panel.contentView = nil
            }
        }
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(
            // Never takes focus from the app in front. `place(_:)` decides whether it also shows
            // over full-screen apps.
            showsOverFullScreenApps: false,
            isDark: false
        )
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
                self.showsTimeAloneChanged(Self.showsTimeAlone)
            }
        }
        return panel
    }

    /// The island's frame on screen while it's shown.
    var frame: NSRect? {
        isShown ? panel?.frame : nil
    }

    /// The screen that has a notch, else the main screen.
    static var screen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
    }

    /// Whether the island is enough to show the time, so the menu bar can leave it out: it's over
    /// the notch of the only screen, where it shows even over full-screen apps. With another
    /// display, the island stays on the notch while the user may be looking at the other one; and
    /// without a notch, a full-screen app hides it. The menu bar shows the time too then.
    private static var showsTimeAlone: Bool {
        guard NSScreen.screens.count == 1, let screen = NSScreen.screens.first else { return false }
        return notch(on: screen).width > 0
    }

    /// Gives `panel` a view laid out for the notch and `layout`, and sizes it around the notch.
    private func place(_ panel: NotchPanel) {
        guard let screen = Self.screen else { return }
        let notch = Self.notch(on: screen)
        let hostingView = NSHostingView(
            rootView: DynamicIslandView(
                environment: environment,
                notchWidth: gap(for: notch).width,
                layout: layout,
                presence: presence,
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

    /// The space between the wings: `notch`, or without one, room for the live text to be wide
    /// enough to read.
    private func gap(for notch: NSRect) -> NSRect {
        guard notch.width == 0, layout.showsLiveText else { return notch }
        return notch.insetBy(dx: -DynamicIslandView.liveTextGapWidth / 2, dy: 0)
    }

    /// The island's frame: the wings, each as wide as its content, either side of `notch`, and the
    /// live text under all three.
    private func frame(around notch: NSRect) -> NSRect {
        let gap = gap(for: notch)
        let levelsWidth = layout.showsLevels ? DynamicIslandView.levelsWingWidth : 0
        let (left, right) =
            layout.timeSide == .left ? (timeWingWidth, levelsWidth) : (levelsWidth, timeWingWidth)
        let width = left + gap.width + right
        // Without a notch to grow out of: centered.
        let x = gap.width == 0 ? gap.midX - width / 2 : gap.minX - left
        let liveTextHeight = layout.showsLiveText ? DynamicIslandView.liveTextHeight : 0
        return NSRect(x: x, y: gap.minY - liveTextHeight, width: width, height: gap.height + liveTextHeight)
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
