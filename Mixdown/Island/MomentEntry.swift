import AppKit
import MixdownCore
import SwiftUI

/// A moment just marked, while the user writes a few words about it.
@MainActor @Observable
final class MomentDraft {
    let moment: Moment
    /// As typed; the coordinator gets it trimmed with every change.
    var text = ""

    init(moment: Moment) {
        self.moment = moment
    }
}

/// A field that drops down under the notch, or under the Dynamic Island while it's shown, to write
/// a few words about the moment just marked, from any app.
///
/// It takes the keyboard without bringing Mixdown to the front, so the app that was in front gets
/// it back as soon as the field closes: on Return, Escape, clicking elsewhere, or after a few
/// seconds without typing (see `AppEnvironment.markMoment()`).
@MainActor
final class MomentEntry {
    private static let size = NSSize(width: 320, height: 32)
    /// Space between the field and the notch or island above it.
    private static let spacing: CGFloat = 6

    private let environment: AppEnvironment
    /// The Dynamic Island's frame while it's shown, to go under it.
    private let islandFrame: () -> NSRect?
    /// Created on the first `show(_:)`, as windows shouldn't be made before the app has launched.
    private var panel: MomentPanel?
    /// The draft the field is showing, if it's open.
    private var shownDraft: MomentDraft?

    init(environment: AppEnvironment, islandFrame: @escaping () -> NSRect?) {
        self.environment = environment
        self.islandFrame = islandFrame
    }

    /// Opens the field for `draft`, taking the keyboard, or switches it to `draft` if it's open.
    func show(_ draft: MomentDraft) {
        guard draft !== shownDraft else { return }
        shownDraft = draft
        let panel = panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: MomentEntryView(environment: environment, draft: draft))
        place(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closes the field, which hands the keyboard back to the app in front.
    func hide() {
        guard shownDraft != nil, let panel else { return }
        shownDraft = nil
        panel.orderOut(nil)
        panel.contentView = nil
    }

    private func makePanel() -> MomentPanel {
        let panel = MomentPanel()
        self.panel = panel
        // Clicking anywhere else, or switching apps, leaves the moment with what was typed so far.
        _ = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shownDraft != nil else { return }
                self.environment.finishMomentDraft()
            }
        }
        return panel
    }

    /// Centers the field under the notch, or under the island while it's shown.
    private func place(_ panel: MomentPanel) {
        guard let screen = DynamicIsland.screen else { return }
        let notch = DynamicIsland.notch(on: screen)
        let top = islandFrame()?.minY ?? notch.minY
        panel.setFrame(
            NSRect(
                x: notch.midX - Self.size.width / 2,
                y: top - Self.spacing - Self.size.height,
                width: Self.size.width,
                height: Self.size.height
            ),
            display: true
        )
    }
}

/// A panel that can take the keyboard without activating Mixdown, over every Space and
/// full-screen app, as the moment can be marked from any of them.
private final class MomentPanel: NSPanel {
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
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Keeps the panel up by the menu bar, where AppKit would otherwise move a window out from.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// A bookmark, the moment's time, and a field for a note on it, in black like the island.
private struct MomentEntryView: View {
    let environment: AppEnvironment
    let draft: MomentDraft

    @FocusState private var isFocused: Bool
    /// Grows in from the notch once shown.
    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 10))
                .foregroundStyle(.yellow)
            Text(MenuBarLabel.elapsedText(Int(draft.moment.time)))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize()
            TextField(
                "Add a note, then press Return",
                text: Binding(get: { draft.text }, set: { environment.describeMoment($0) })
            )
            .textFieldStyle(.plain)
            .foregroundStyle(.white)
            .focused($isFocused)
            .onSubmit { environment.finishMomentDraft() }
            // Keeps the mark, without the note.
            .onExitCommand { environment.finishMomentDraft(discardingText: true) }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
        .environment(\.colorScheme, .dark)
        .scaleEffect(isExpanded ? 1 : 0.9, anchor: .top)
        .opacity(isExpanded ? 1 : 0)
        .onAppear {
            isFocused = true
            withAnimation(.smooth(duration: 0.25)) { isExpanded = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Moment at \(Duration.seconds(Int(draft.moment.time)).formatted(.units(width: .wide)))"
        )
    }
}
