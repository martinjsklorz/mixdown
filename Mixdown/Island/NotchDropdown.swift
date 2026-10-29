import AppKit
import MixdownCore

/// A panel that drops down under the notch, or under the Dynamic Island while it's shown, for
/// `MomentEntry` and `CatchUpCard`. Stays under it as displays change and as the island shows
/// or hides; see `IslandController.observeDynamicIsland()`.
@MainActor
final class NotchDropdown {
    /// Space between the panel and the notch or island above it.
    private static let spacing: CGFloat = 6

    /// The Dynamic Island's frame while it's shown, to go under it.
    private let islandFrame: () -> NSRect?
    private let makePanel: () -> NotchPanel
    /// Created on the first `show(_:size:)`, as windows shouldn't be made before the app has
    /// launched.
    private var panel: NotchPanel?
    private var size = NSSize.zero
    private(set) var isShown = false

    /// - Parameter makePanel: Makes the panel, the first time it's shown.
    init(islandFrame: @escaping () -> NSRect?, makePanel: @escaping () -> NotchPanel) {
        self.islandFrame = islandFrame
        self.makePanel = makePanel
    }

    /// Puts `contentView` in the panel, `size` big, and places it. Returns the panel, for the
    /// caller to bring to the front as it needs to.
    func show(_ contentView: NSView, size: NSSize) -> NotchPanel {
        let panel = panel ?? createPanel()
        isShown = true
        self.size = size
        panel.contentView = contentView
        place()
        return panel
    }

    /// Takes the panel off screen and ends its view.
    func hide() {
        guard isShown, let panel else { return }
        isShown = false
        panel.orderOut(nil)
        panel.contentView = nil
    }

    /// Makes the panel `size` big, keeping it under the notch or island.
    func resize(to size: NSSize) {
        self.size = size
        place()
    }

    /// Centers the panel under the notch, or under the island while it's shown.
    func place() {
        guard isShown, let panel, let screen = DynamicIsland.screen else { return }
        let frame = NotchLayout.dropdownFrame(
            notch: DynamicIsland.notch(on: screen),
            islandFrame: islandFrame(),
            size: size,
            spacing: Self.spacing
        )
        panel.setFrame(frame, display: true)
    }

    private func createPanel() -> NotchPanel {
        let panel = makePanel()
        self.panel = panel
        // Follows displays being connected, rearranged or changing resolution. On the next turn
        // of the run loop, once the island has moved for the same change.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.place() }
        }
        return panel
    }
}
