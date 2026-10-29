import AppKit
import MixdownCore
import SwiftUI

/// A moment just marked, while the user writes a few words about it. It only goes into the note
/// on Return; see `IslandController.markMoment()`.
@MainActor @Observable
final class MomentDraft {
    /// Where in the recording it was marked. See `RecordingCoordinator.momentTime`.
    let time: TimeInterval
    var text = ""

    init(time: TimeInterval) {
        self.time = time
    }
}

/// A field that drops down under the notch, or under the Dynamic Island while it's shown, to write
/// a few words about the moment just marked, from any app.
///
/// It takes the keyboard without bringing Mixdown to the front, so the app that was in front gets
/// it back as soon as the field closes: on Return, Escape, clicking elsewhere, or after a few
/// seconds without typing (see `IslandController.markMoment()`). Should the panel not get the
/// keyboard that way, Mixdown comes to the front, and hands it back to that app on closing.
@MainActor
final class MomentEntry {
    private static let size = NSSize(width: 320, height: 32)

    private let island: IslandController
    /// The Dynamic Island's frame while it's shown, to go under it.
    private let islandFrame: () -> NSRect?
    private lazy var dropdown = NotchDropdown(islandFrame: islandFrame) { [unowned self] in makePanel() }
    /// The draft the field is showing, if it's open.
    private var shownDraft: MomentDraft?
    /// The app that was in front, while Mixdown had to come forward for the field to get the
    /// keyboard.
    private var appToReactivate: NSRunningApplication?

    init(island: IslandController, islandFrame: @escaping () -> NSRect?) {
        self.island = island
        self.islandFrame = islandFrame
    }

    /// Opens the field for `draft`, taking the keyboard, or switches it to `draft` if it's open.
    func show(_ draft: MomentDraft) {
        guard draft !== shownDraft else { return }
        shownDraft = draft
        let panel = dropdown.show(
            NSHostingView(rootView: MomentEntryView(island: island, draft: draft)),
            size: Self.size
        )
        panel.makeKeyAndOrderFront(nil)
        // A nonactivating panel normally gets the keyboard as it is; just in case it didn't.
        Task { [weak self] in
            guard let self, self.shownDraft === draft, !panel.isKeyWindow, !NSApp.isActive else { return }
            self.appToReactivate = NSWorkspace.shared.frontmostApplication
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Closes the field, which hands the keyboard back to the app in front.
    func hide() {
        guard shownDraft != nil else { return }
        shownDraft = nil
        dropdown.hide()
        if let app = appToReactivate {
            appToReactivate = nil
            app.activate(options: [])
        }
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(
            // Takes the keyboard without activating Mixdown, over every Space and full-screen app,
            // as the moment can be marked from any of them.
            canBecomeKey: true,
            showsOverFullScreenApps: true,
            // Light text and caret on black, whatever the system appearance.
            isDark: true
        )
        // Clicking anywhere else, or switching apps, drops the moment, like Escape.
        _ = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shownDraft != nil else { return }
                self.island.closeMomentDraft()
            }
        }
        return panel
    }

    /// Moves the field under the island, or up under the notch, as the island shows or hides.
    func islandMoved() {
        dropdown.place()
    }
}

/// A bookmark, the moment's time, and a field for a note on it, in black like the island.
private struct MomentEntryView: View {
    let island: IslandController
    @Bindable var draft: MomentDraft

    /// Grows in from the notch once shown.
    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 10))
                .foregroundStyle(.yellow)
            Text(ProgressText.elapsed(Int(draft.time)))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize()
            MomentTextField(
                text: $draft.text,
                onSubmit: { island.addMomentDraft() },
                onCancel: { island.closeMomentDraft() }
            )
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
            withAnimation(.smooth(duration: 0.25)) { isExpanded = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Moment at \(Duration.seconds(Int(draft.time)).formatted(.units(width: .wide)))"
        )
    }
}

/// The note field, in AppKit: it has to have the keyboard as soon as the panel shows, which
/// SwiftUI's focus doesn't manage in a panel of an app that isn't in front.
private struct MomentTextField: NSViewRepresentable {
    @Binding var text: String
    /// On Return.
    let onSubmit: () -> Void
    /// On Escape.
    let onCancel: () -> Void

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.font = .systemFont(ofSize: 13)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(
            string: "Add a note, then press Return",
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.4), .font: NSFont.systemFont(ofSize: 13)]
        )
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MomentTextField

        init(parent: MomentTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

/// Takes the keyboard as soon as it's in a window.
private final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}
