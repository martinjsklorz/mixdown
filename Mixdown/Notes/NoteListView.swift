import AppKit
import MixdownCore
import MixdownNotes
import SwiftUI

/// The sidebar list of notes in sections: pinned notes, then today, the previous seven days and
/// by month. The pinned section folds away under its header, and the header of the section
/// scrolled to the top stays there while its notes scroll under it.
///
/// Drawn by hand rather than with `List(selection:)`: macOS paints a list's selection in the
/// system accent color, and this highlights the selected note in Mixdown's orange like Apple
/// Notes does in yellow. Arrow keys move the selection once the list has focus, and Delete moves
/// the selected note to the Trash.
struct NoteListView<Footer: View>: View {
    let sections: [NoteSection]
    @Binding var selection: NoteDocument.ID?
    /// Whether to highlight `selection`; not while another section of the window is showing.
    var showsSelection = true
    /// Whether the pinned notes are folded away under their section header.
    @Binding var collapsesPinned: Bool
    let actions: NoteActions
    /// Shown instead of the notes when there are none, e.g. an empty or error state.
    @ViewBuilder var footer: Footer
    @FocusState private var isFocused: Bool
    /// The rows at least partly in view, not necessarily top to bottom.
    @State private var visibleRows: [Row.ID] = []
    /// Where the headers in view sit, from the top of the list's visible area.
    @State private var headerOffsets: [NoteSection.Group: CGFloat] = [:]
    @State private var stickyHeaderHeight: CGFloat = 0
    /// How tall the pinned notes' rows are unfolded, for folding them away.
    @State private var pinnedRowHeights: [NoteDocument.ID: CGFloat] = [:]
    /// Whether the pinned rows are laid out folded, once that's changed while the list is shown.
    /// Follows `collapsesPinned` without animating, so the pinned notes never move.
    @State private var foldsPinnedRows: Bool?
    /// How far the rows below the pinned notes are drawn from their place, while they slide over
    /// the pinned notes or off them.
    @State private var foldSlide: CGFloat = 0

    var body: some View {
        let rows = self.rows

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // One flat list rather than one per section, so a note that's pinned or
                    // unpinned moves to its new place instead of leaving one list and appearing
                    // in another, which could leave a stale copy of its row behind.
                    ForEach(rows) { row in
                        switch row {
                        case .header(let group):
                            header(for: group)
                                .onGeometryChange(for: CGFloat.self) {
                                    $0.frame(in: .scrollView).minY
                                } action: {
                                    headerOffsets[group] = $0
                                }
                                .padding(.vertical, 1)
                                .offset(y: group == .pinned ? 0 : foldSlide)
                        case .note(let note, let dateFormat) where note.isPinned:
                            pinnedNoteButton(note, dateFormat: dateFormat)
                        case .note(let note, let dateFormat):
                            noteButton(note, dateFormat: dateFormat)
                                .padding(.vertical, 1)
                                .offset(y: foldSlide)
                        }
                    }
                    .transition(.noteRow)
                    footer
                        .offset(y: foldSlide)
                }
                .scrollTargetLayout()
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .mask(alignment: .top) { stickyHeaderMask(in: rows) }
            }
            .onScrollTargetVisibilityChange(idType: Row.ID.self) { visibleRows = $0 }
            .overlay(alignment: .top) { stickyHeader(in: rows) }
            .onChange(of: collapsesPinned) { _, isFolded in slideRows(folding: isFolded) }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { moveSelection(by: 1, in: rows, proxy: proxy) }
            .onKeyPress(.upArrow) { moveSelection(by: -1, in: rows, proxy: proxy) }
            // ⌫, ⌦ and Edit → Delete trash the selected note.
            .onDeleteCommand {
                guard showsSelection,
                    let note = sections.lazy.flatMap(\.notes).first(where: { $0.id == selection })
                else { return }
                actions.moveToTrash(note)
            }
        }
    }

    /// The section headers and the notes under them, the pinned ones too while they're folded
    /// away.
    private var rows: [Row] {
        sections.flatMap { section -> [Row] in
            [.header(section.group)]
                + section.notes.map { .note($0, dateFormat: section.group.rowDateFormat(for: $0)) }
        }
    }

    /// Whether `row` is a pinned note folded away under its header.
    private func isFolded(_ row: Row) -> Bool {
        collapsesPinned && row.noteID != nil && row.group == .pinned
    }

    private var pinnedNotes: [NoteDocument] {
        sections.first { $0.group == .pinned }?.notes ?? []
    }

    /// How tall the rows of the pinned `notes` are together, unfolded.
    private func unfoldedHeight(of notes: some Sequence<NoteDocument>) -> CGFloat {
        notes.reduce(0) { $0 + (pinnedRowHeights[$1.id] ?? 0) }
    }

    /// Folds the pinned notes away under the rows below as they slide up over them, or opens them
    /// as the rows slide back down. The rows are laid out folded or not at once and drawn where
    /// they were, and only that offset animates: the lazy stack moves the pinned notes when it
    /// animates their rows shrinking or growing.
    private func slideRows(folding: Bool) {
        let height = unfoldedHeight(of: pinnedNotes)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            foldsPinnedRows = folding
            foldSlide = folding ? height : -height
        }
        // Once drawn there, so the slide starts from it.
        Task { @MainActor in
            withAnimation(.snappy) { foldSlide = 0 }
        }
    }

    /// A pinned note's row. Folded, it takes no room, and its note stays where it was and fades
    /// under the rows below as they slide over it. Kept in the list while folded, as a row
    /// removed from a lazy stack doesn't hold still while it fades out.
    private func pinnedNoteButton(_ note: NoteDocument, dateFormat: Date.FormatStyle) -> some View {
        let isFolded = collapsesPinned
        let isLaidOutFolded = foldsPinnedRows ?? collapsesPinned
        // Under the pinned notes above it, which take no room either.
        let heightAbove = unfoldedHeight(of: pinnedNotes.prefix { $0.id != note.id })

        return noteButton(note, dateFormat: dateFormat)
            .padding(.vertical, 1)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                pinnedRowHeights[note.id] = $0
            }
            // Out before the notes sliding over it reach it, and in once they've moved off it.
            .animation(isFolded ? .easeOut(duration: 0.15) : .easeIn(duration: 0.2).delay(0.15)) {
                $0.opacity(isFolded ? 0 : 1)
            }
            .offset(y: isLaidOutFolded ? heightAbove : 0)
            .frame(height: isLaidOutFolded ? 0 : nil, alignment: .top)
            .zIndex(-1)
            .allowsHitTesting(!isFolded)
            .accessibilityHidden(isFolded)
    }

    private func header(for group: NoteSection.Group) -> NoteSectionHeader {
        NoteSectionHeader(title: group.title, isCollapsed: group == .pinned ? $collapsesPinned : nil)
    }

    /// The header of the section at the top of the list once its own has scrolled up out of
    /// view. Drawn over the flat list rather than with pinned `Section` headers, which would split
    /// it into one list per section. The next section's header pushes it up and out as it arrives.
    @ViewBuilder
    private func stickyHeader(in rows: [Row]) -> some View {
        if let placement = stickyHeaderPlacement(in: rows) {
            ZStack {
                header(for: placement.group)
                    .padding(.horizontal, 10)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        stickyHeaderHeight = $0
                    }
                    .offset(y: placement.push)
            }
            .clipped()
            // Lets clicks and scrolling through to the list, except on a header that folds.
            .allowsHitTesting(placement.group == .pinned)
        }
    }

    /// The section whose header stays at the top of the list, and how far up the next section's
    /// header has pushed it, while its own header is scrolled up out of view.
    private func stickyHeaderPlacement(in rows: [Row]) -> (group: NoteSection.Group, push: CGFloat)? {
        // Stale for rows out of view, so only the offsets of headers in view count.
        // Folded rows count as in view at the top of their section, but take no room.
        // In the list's order, as the visible rows don't come top to bottom: the pinned notes,
        // drawn under the rest, come before their header, whose sticky copy would then cover it
        // 1pt higher than it sits.
        let visibleIDs = Set(visibleRows)
        let shownRows = rows.filter { visibleIDs.contains($0.id) && !isFolded($0) }
        guard let top = shownRows.first, top.id != .header(top.group) || headerOffsets[top.group, default: 0] < 0
        else { return nil }
        let groups = sections.map(\.group)
        let next = zip(groups, groups.dropFirst()).first { $0.0 == top.group }?.1
        let nextOffset = next.flatMap { visibleRows.contains(.header($0)) ? headerOffsets[$0] : nil }
        return (top.group, nextOffset.map { min(0, $0 - stickyHeaderHeight) } ?? 0)
    }

    /// Hides the notes scrolled under the sticky header, so it shows the sidebar's own background
    /// behind it: no material drawn over the list matches the sidebar's. Masks the list's content
    /// rather than the scroll view, which would cut the sidebar's background out from under the
    /// header too and show the window's through it.
    private func stickyHeaderMask(in rows: [Row]) -> some View {
        let hiddenHeight = stickyHeaderPlacement(in: rows).map { max(0, stickyHeaderHeight + $0.push) } ?? 0
        return GeometryReader { proxy in
            // How far the content has scrolled up past the top of the list's visible area.
            let scrolled = max(0, -proxy.frame(in: .scrollView).minY)
            VStack(spacing: 0) {
                Color.clear.frame(height: scrolled + hiddenHeight)
                Rectangle()
            }
            // Past the content's end too, for the notes drawn below it while they slide up over
            // the pinned notes folding away.
            .frame(height: proxy.size.height * 2, alignment: .top)
        }
    }

    private func noteButton(_ note: NoteDocument, dateFormat: Date.FormatStyle) -> some View {
        // A button, so VoiceOver announces it and Space or Return opens it once it has keyboard
        // focus.
        Button {
            selection = note.id
            isFocused = true
        } label: {
            NoteRow(note: note, dateFormat: dateFormat, isSelected: showsSelection && note.id == selection)
                .contentShape(Rectangle())
        }
        .buttonStyle(.unpressed)
        .accessibilityAddTraits(showsSelection && note.id == selection ? .isSelected : [])
        .contextMenu {
            Button(note.isPinned ? "Unpin Note" : "Pin Note") { actions.togglePinned(note) }
            Button("Rename…") { actions.rename(note) }
            RenameSpeakerMenu(note: note, actions: actions) { Text("Rename Speaker") }
            Button("Copy Transcript") { NoteActions.copyTranscript(of: note) }
            ShareLink(item: note.url, preview: SharePreview(note.title))
            Divider()
            Button("Open in Default App") { NSWorkspace.shared.open(note.url) }
            Divider()
            Button("Delete") { actions.moveToTrash(note) }
        }
    }

    /// Moves the selection among the notes shown, skipping folded-away ones.
    private func moveSelection(by offset: Int, in rows: [Row], proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = rows.filter { !isFolded($0) }.compactMap(\.noteID)
        guard !ids.isEmpty else { return .ignored }
        let current = showsSelection ? selection : nil
        let index = current.flatMap(ids.firstIndex(of:)).map { $0 + offset } ?? 0
        let id = ids[min(max(index, 0), ids.count - 1)]
        selection = id
        proxy.scrollTo(Row.ID.note(id))
        return .handled
    }
}

/// A line of the sidebar list: a section's header or one of its notes.
private enum Row: Identifiable {
    case header(NoteSection.Group)
    case note(NoteDocument, dateFormat: Date.FormatStyle)

    enum ID: Hashable {
        case header(NoteSection.Group)
        case note(NoteDocument.ID)
    }

    var id: ID {
        switch self {
        case .header(let group): .header(group)
        case .note(let note, _): .note(note.id)
        }
    }

    var noteID: NoteDocument.ID? {
        guard case .note(let note, _) = self else { return nil }
        return note.id
    }

    /// The section the row belongs to.
    var group: NoteSection.Group {
        switch self {
        case .header(let group): group
        case .note(let note, _): note.isPinned ? .pinned : .date(NoteDateGroup(date: note.createdAt))
        }
    }
}

extension AnyTransition {
    /// A row slides down into its place as it's added and up out of it as it's removed, fading
    /// in and out, while the rows below move to make room or close the gap.
    fileprivate static var noteRow: AnyTransition { .move(edge: .top).combined(with: .opacity) }
}

extension ButtonStyle where Self == UnpressedButtonStyle {
    /// Like `.plain`, without dimming the label while the mouse button is held down on it.
    static var unpressed: UnpressedButtonStyle { UnpressedButtonStyle() }
}

struct UnpressedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

extension NoteSection.Group {
    fileprivate var title: String {
        switch self {
        case .pinned: "Pinned"
        case .date(let group): group.title
        }
    }

    /// How the rows show when `note` was recorded. Pinned notes show it as they would in their
    /// date's section.
    fileprivate func rowDateFormat(for note: NoteDocument) -> Date.FormatStyle {
        switch self {
        case .pinned: NoteDateGroup(date: note.createdAt).rowDateFormat
        case .date(let group): group.rowDateFormat
        }
    }
}

extension NoteDateGroup {
    fileprivate var title: String {
        switch self {
        case .today: "Today"
        case .previousSevenDays: "Previous 7 Days"
        // "September", with the year once it's not this year's.
        case .month(let date) where Calendar.current.isDate(date, equalTo: .now, toGranularity: .year):
            date.formatted(.dateTime.month(.wide))
        case .month(let date):
            date.formatted(.dateTime.month(.wide).year())
        }
    }

    /// How a note's rows show when it was recorded: the time today, the weekday in the previous
    /// seven days, and the date before that.
    fileprivate var rowDateFormat: Date.FormatStyle {
        switch self {
        case .today: .dateTime.hour().minute()
        case .previousSevenDays: .dateTime.weekday(.wide)
        case .month: .dateTime.day().month(.twoDigits).year(.twoDigits)
        }
    }
}
