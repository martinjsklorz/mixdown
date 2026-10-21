import AppKit
import MixdownCore
import SwiftUI

/// A catch-up the user asked for, while it's summed up and then shown. See
/// `AppEnvironment.catchUp()`.
@MainActor @Observable
final class CatchUpRequest {
    enum State: Equatable {
        case summarizing
        case ready(CatchUp)
        /// The message says why there's no catch-up.
        case failed(String)
    }

    /// How many of the last minutes it's about.
    let minutes: Int
    var state = State.summarizing
    /// Whether the pointer is over the card, which keeps it open.
    var isHovered = false

    init(minutes: Int) {
        self.minutes = minutes
    }
}

/// A card that drops down under the notch, or under the Dynamic Island while it's shown, with what
/// was said in the last few minutes, for when the user drifted off.
///
/// Unlike the field for a moment, it never takes the keyboard, so the app in front keeps it. It
/// closes when clicked, on the Catch Me Up shortcut again, or a while after it's been read (see
/// `AppEnvironment.catchUp()`).
@MainActor
final class CatchUpCard {
    static let width: CGFloat = 360
    /// Space between the card and the notch or island above it.
    private static let spacing: CGFloat = 6

    private let environment: AppEnvironment
    /// The Dynamic Island's frame while it's shown, to go under it.
    private let islandFrame: () -> NSRect?
    /// Created on the first `show(_:)`, as windows shouldn't be made before the app has launched.
    private var panel: CatchUpPanel?
    /// The request the card is showing, if it's open.
    private var shownRequest: CatchUpRequest?
    /// As tall as the view last measured itself, which changes once the catch-up is in.
    private var height = initialHeight
    /// About the height of the card while it's summing up, until the view has measured itself.
    private static let initialHeight: CGFloat = 40

    init(environment: AppEnvironment, islandFrame: @escaping () -> NSRect?) {
        self.environment = environment
        self.islandFrame = islandFrame
    }

    /// Opens the card for `request`, or switches it to `request` if it's open.
    func show(_ request: CatchUpRequest) {
        guard request !== shownRequest else { return }
        shownRequest = request
        // Not as tall as the last catch-up, which would leave clear space under the card that
        // takes clicks.
        height = Self.initialHeight
        let panel = panel ?? makePanel()
        let hostingView = NSHostingView(
            rootView: CatchUpView(
                environment: environment,
                request: request,
                heightChanged: { [weak self] height in self?.heightChanged(height) }
            )
        )
        // The panel is sized here, from the height the view reports, so it grows downwards.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        place(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        guard shownRequest != nil, let panel else { return }
        shownRequest = nil
        panel.orderOut(nil)
        // Ends the view, and with it the hover tracking.
        panel.contentView = nil
    }

    private func makePanel() -> CatchUpPanel {
        let panel = CatchUpPanel()
        self.panel = panel
        return panel
    }

    private func heightChanged(_ height: CGFloat) {
        guard abs(height - self.height) >= 0.5 else { return }
        self.height = height
        guard shownRequest != nil, let panel else { return }
        place(panel)
    }

    /// Centers the card under the notch, or under the island while it's shown.
    private func place(_ panel: CatchUpPanel) {
        guard let screen = DynamicIsland.screen else { return }
        let notch = DynamicIsland.notch(on: screen)
        let top = (islandFrame()?.minY ?? notch.minY) - Self.spacing
        panel.setFrame(
            NSRect(x: notch.midX - Self.width / 2, y: top - height, width: Self.width, height: height),
            display: true
        )
    }
}

/// A panel over every Space and full-screen app, as a catch-up can be asked for from any of them,
/// that never takes focus from the app in front.
private final class CatchUpPanel: NSPanel {
    convenience init() {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Keeps the panel up by the menu bar, where AppKit would otherwise move a window out from.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// What was missed, as a few points under a heading, in black like the island. While Apple
/// Intelligence is at it, a spinner; if it can't, why not.
private struct CatchUpView: View {
    let environment: AppEnvironment
    let request: CatchUpRequest
    /// Called with the card's height whenever that changes.
    let heightChanged: (CGFloat) -> Void

    /// Grows in from the notch once shown.
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "apple.intelligence")
                    .symbolRenderingMode(.multicolor)
                Text(heading)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
                if request.state == .summarizing {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            switch request.state {
            case .summarizing:
                EmptyView()
            case .ready(let catchUp):
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(catchUp.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                                .foregroundStyle(.white.opacity(0.5))
                            Text(point)
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .transition(.opacity)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: CatchUpCard.width, alignment: .leading)
        .background(.black, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15)))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { heightChanged($0) }
        .environment(\.colorScheme, .dark)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { environment.closeCatchUp() }
        .onHover { request.isHovered = $0 }
        .help("Click to close")
        .scaleEffect(isExpanded ? 1 : 0.9, anchor: .top)
        .opacity(isExpanded ? 1 : 0)
        .animation(.smooth(duration: 0.25), value: request.state)
        // The panel is as tall as the card; the top stays put while it grows.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(.smooth(duration: 0.25)) { isExpanded = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Catch Me Up")
    }

    private var heading: String {
        switch request.state {
        case .summarizing:
            "Catching up on the \(Self.lastMinutes(request.minutes))…"
        case .ready(let catchUp):
            // Fewer if the recording isn't that long yet.
            Self.lastMinutes(min(Int((catchUp.duration / 60).rounded(.up)), request.minutes)).capitalizedFirst
        case .failed:
            "Can't catch up"
        }
    }

    /// E.g. "last 5 minutes", or "last minute".
    private static func lastMinutes(_ minutes: Int) -> String {
        minutes <= 1 ? "last minute" : "last \(minutes) minutes"
    }
}

extension String {
    /// With the first letter upper-cased, e.g. for a heading.
    fileprivate var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
