import AppKit
import MixdownCore
import MixdownNotes
import SwiftUI

/// The sidebar list of notes in sections: pinned notes, then today, the previous seven days and
/// by month. The pinned section folds away under its header.
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
                            SectionHeader(
                                title: group.title,
                                isCollapsed: group == .pinned ? $collapsesPinned : nil
                            )
                        case .note(let note, let dateFormat):
                            noteButton(note, dateFormat: dateFormat)
                        }
                    }
                    .transition(.noteRow)
                    footer
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
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
                .padding(Self.padding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isCollapsed.wrappedValue ? "Collapsed" : "Expanded")
            .accessibilityHint(isCollapsed.wrappedValue ? "Shows the notes" : "Hides the notes")
        } else {
            text
                .padding(Self.padding)
        }
    }

    private static let padding = EdgeInsets(top: 14, leading: 10, bottom: 4, trailing: 10)

    private var text: some View {
        Text(title)
            .font(.body.weight(.semibold))
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
