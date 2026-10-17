import AppKit
import MixdownNotes
import SwiftUI

/// The sidebar list of notes in collapsible sections by day, below `header` (the main window's
/// other sections).
///
/// Drawn by hand rather than with `List(selection:)`: macOS paints a list's selection in the
/// system accent color, and this highlights the selected note in Mixdown's orange like Apple
/// Notes does in yellow. Arrow keys move the selection once the list has focus, and Delete moves
/// the selected note to the Trash.
struct NoteListView<Header: View, Footer: View>: View {
    let sections: [NoteSection]
    @Binding var selection: NoteDocument.ID?
    /// Whether to highlight `selection`; not while another section of the window is showing.
    var showsSelection = true
    let actions: NoteActions
    @ViewBuilder var header: Header
    /// Shown instead of the notes when there are none, e.g. an empty or error state.
    @ViewBuilder var footer: Footer
    @State private var collapsed: Set<NoteDateGroup> = []
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    header
                    ForEach(sections) { section in
                        let isCollapsed = collapsed.contains(section.group)
                        SectionHeader(section: section, isCollapsed: isCollapsed) {
                            withAnimation(.snappy) { collapsed.formSymmetricDifference([section.group]) }
                        }
                        ForEach(isCollapsed ? [] : section.notes) { note in
                            // A button, so VoiceOver announces it and Space or Return opens it
                            // once it has keyboard focus.
                            Button {
                                selection = note.id
                                isFocused = true
                            } label: {
                                NoteRow(note: note, isSelected: showsSelection && note.id == selection)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(showsSelection && note.id == selection ? .isSelected : [])
                            .contextMenu {
                                Button("Rename…") { actions.rename(note) }
                                Button("Copy Transcript") { NoteActions.copyTranscript(of: note) }
                                ShareLink(item: note.url, preview: SharePreview(note.title))
                                Divider()
                                Button("Open in Default App") { NSWorkspace.shared.open(note.url) }
                                Divider()
                                Button("Delete") { actions.moveToTrash(note) }
                            }
                            .id(note.id)
                        }
                    }
                    footer
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { moveSelection(by: 1, proxy: proxy) }
            .onKeyPress(.upArrow) { moveSelection(by: -1, proxy: proxy) }
            // ⌫, ⌦ and Edit → Delete trash the selected note.
            .onDeleteCommand {
                guard showsSelection,
                    let note = sections.lazy.flatMap(\.notes).first(where: { $0.id == selection })
                else { return }
                actions.moveToTrash(note)
            }
            // Expand the day of a note selected from elsewhere, such as one just recorded.
            .onChange(of: selection) { _, id in
                if let group = sections.first(where: { $0.notes.contains { $0.id == id } })?.group {
                    collapsed.remove(group)
                }
            }
        }
    }

    /// Moves through the notes of expanded days.
    private func moveSelection(by offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = sections.filter { !collapsed.contains($0.group) }.flatMap { $0.notes.map(\.id) }
        guard !ids.isEmpty else { return .ignored }
        let current = showsSelection ? selection : nil
        let index = current.flatMap(ids.firstIndex(of:)).map { $0 + offset } ?? 0
        let id = ids[min(max(index, 0), ids.count - 1)]
        selection = id
        proxy.scrollTo(id)
        return .handled
    }
}

/// A day's title, which collapses or expands its notes.
private struct SectionHeader: View {
    let section: NoteSection
    let isCollapsed: Bool
    let toggle: @MainActor () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(section.group.title)
                    .font(.body.weight(.semibold))
                Spacer()
                if isCollapsed {
                    Text(section.notes.count, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .help(isCollapsed ? "Show recordings" : "Hide recordings")
    }
}

private struct NoteRow: View {
    let note: NoteDocument
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .font(.body.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(note.createdAt, format: .dateTime.hour().minute())
                Text(note.snippet.isEmpty ? "No additional text" : note.snippet)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The light orange of the app icon's tracks (a darker icon orange in Dark Mode).
        .background(isSelected ? Color("NoteSelection") : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

extension NoteDateGroup {
    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        // "Monday, October 12", with the year once it's not this year's.
        case .day(let date) where Calendar.current.isDate(date, equalTo: .now, toGranularity: .year):
            date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        case .day(let date):
            date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        }
    }
}
