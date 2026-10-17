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
    /// The rows at least partly in view, top to bottom.
    @State private var visibleRows: [Row.ID] = []
    /// Where the headers in view sit, from the top of the list's visible area.
    @State private var headerOffsets: [NoteSection.Group: CGFloat] = [:]
    @State private var stickyHeaderHeight: CGFloat = 0

    var body: some View {
        let rows = self.rows

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
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
                        case .note(let note, let dateFormat):
                            noteButton(note, dateFormat: dateFormat)
                        }
                    }
                    .transition(.noteRow)
                    footer
                }
                .scrollTargetLayout()
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .onScrollTargetVisibilityChange(idType: Row.ID.self) { visibleRows = $0 }
            .overlay(alignment: .top) { stickyHeader(in: rows) }
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

    /// The section headers and the notes under them, without the pinned ones while they're
    /// folded away.
    private var rows: [Row] {
        sections.flatMap { section -> [Row] in
            let notes = section.group == .pinned && collapsesPinned ? [] : section.notes
            return [.header(section.group)]
                + notes.map { .note($0, dateFormat: section.group.rowDateFormat(for: $0)) }
        }
    }

    private func header(for group: NoteSection.Group) -> SectionHeader {
        SectionHeader(title: group.title, isCollapsed: group == .pinned ? $collapsesPinned : nil)
    }

    /// The header of the section at the top of the list once its own has scrolled up out of
    /// view. Drawn over the flat list rather than with pinned `Section` headers, which would split
    /// it into one list per section. The next section's header pushes it up and out as it arrives.
    @ViewBuilder
    private func stickyHeader(in rows: [Row]) -> some View {
        // Stale for rows out of view, so only the offsets of headers in view count.
        if let top = visibleRows.first, let group = rows.first(where: { $0.id == top })?.group,
            top != .header(group) || headerOffsets[group, default: 0] < 0
        {
            let groups = sections.map(\.group)
            let next = zip(groups, groups.dropFirst()).first { $0.0 == group }?.1
            let nextOffset = next.flatMap { visibleRows.contains(.header($0)) ? headerOffsets[$0] : nil }
            let push = nextOffset.map { min(0, $0 - stickyHeaderHeight) } ?? 0

            ZStack {
                header(for: group)
                    .padding(.horizontal, 10)
                    .background(.bar)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        stickyHeaderHeight = $0
                    }
                    .offset(y: push)
            }
            .clipped()
            // Lets clicks and scrolling through to the list, except on a header that folds.
            .allowsHitTesting(group == .pinned)
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
        .buttonStyle(.plain)
        .accessibilityAddTraits(showsSelection && note.id == selection ? .isSelected : [])
        .contextMenu {
            Button(note.isPinned ? "Unpin Note" : "Pin Note") { actions.togglePinned(note) }
            Button("Rename…") { actions.rename(note) }
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
        let ids = rows.compactMap(\.noteID)
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

/// A section's title, like "Pinned", "Today" or "September". With `isCollapsed`, clicking it
/// folds the section's notes away or shows them again, and a chevron says which.
private struct SectionHeader: View {
    let title: String
    var isCollapsed: Binding<Bool>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
            Divider()
        }
        .padding(EdgeInsets(top: 20, leading: 10, bottom: 6, trailing: 10))
    }

    @ViewBuilder
    private var heading: some View {
        if let isCollapsed {
            Button {
                withAnimation(.snappy) { isCollapsed.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    text
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed.wrappedValue ? 0 : 90))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isCollapsed.wrappedValue ? "Collapsed" : "Expanded")
            .accessibilityHint(isCollapsed.wrappedValue ? "Shows the notes" : "Hides the notes")
        } else {
            text
        }
    }

    private var text: some View {
        Text(title)
            .font(.title2.weight(.bold))
            .accessibilityAddTraits(.isHeader)
    }
}

private struct NoteRow: View {
    let note: NoteDocument
    let dateFormat: Date.FormatStyle
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(note.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let trigger = note.trigger {
                    TriggerIcon(trigger: trigger)
                }
            }
            HStack(spacing: 6) {
                Text(note.createdAt, format: dateFormat)
                Text(note.snippet.isEmpty ? "No additional text" : note.snippet)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.subheadline)
            if let folder = note.folder {
                Label(folder, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The light orange of the app icon's tracks (a darker icon orange in Dark Mode).
        .background(isSelected ? Color("NoteSelection") : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A small mark for how the recording was started. Notes that don't say show none.
private struct TriggerIcon: View {
    let trigger: RecordingTrigger

    var body: some View {
        let (symbol, label) =
            switch trigger {
            case .manual: ("hand.tap", "Started manually")
            case .automatic: ("autostartstop", "Started automatically for a call")
            }
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(label)
            .accessibilityLabel(label)
    }
}

extension NoteSection.Group {
    var title: String {
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
    var title: String {
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
