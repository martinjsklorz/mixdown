import AppKit
import MixdownNotes
import SwiftUI

/// The sidebar list of notes, grouped by date.
///
/// Drawn by hand rather than with `List(selection:)`: macOS paints a list's selection in the
/// system accent color, and this highlights the selected note in Mixdown's orange like Apple
/// Notes does in yellow. Arrow keys move the selection once the list has focus.
struct NoteListView: View {
    let sections: [NoteSection]
    @Binding var selection: NoteDocument.ID?
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sections) { section in
                        Text(section.group.title)
                            .font(.title3.bold())
                            .padding(.horizontal, 10)
                            .padding(.top, section.id == sections.first?.id ? 4 : 16)
                            .padding(.bottom, 4)
                        ForEach(section.notes) { note in
                            NoteRow(note: note, group: section.group, isSelected: note.id == selection)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selection = note.id
                                    isFocused = true
                                }
                                .contextMenu {
                                    Button("Open in Default App") { NSWorkspace.shared.open(note.url) }
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([note.url])
                                    }
                                }
                                .id(note.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { moveSelection(by: 1, proxy: proxy) }
            .onKeyPress(.upArrow) { moveSelection(by: -1, proxy: proxy) }
        }
    }

    private func moveSelection(by offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = sections.flatMap { $0.notes.map(\.id) }
        guard !ids.isEmpty else { return .ignored }
        let index = selection.flatMap(ids.firstIndex(of:)).map { $0 + offset } ?? 0
        let id = ids[min(max(index, 0), ids.count - 1)]
        selection = id
        proxy.scrollTo(id)
        return .handled
    }
}

private struct NoteRow: View {
    let note: NoteDocument
    let group: NoteDateGroup
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(dateText)
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

    /// Like Apple Notes: the time today, the weekday this week, else the date.
    private var dateText: String {
        switch group {
        case .today: note.createdAt.formatted(date: .omitted, time: .shortened)
        case .yesterday: "Yesterday"
        case .previous7Days: note.createdAt.formatted(.dateTime.weekday(.wide))
        default: note.createdAt.formatted(date: .numeric, time: .omitted)
        }
    }
}

extension NoteDateGroup {
    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .previous7Days: "Previous 7 Days"
        case .previous30Days: "Previous 30 Days"
        case .month(let month): Calendar.current.standaloneMonthSymbols[month - 1]
        case .year(let year): String(year)
        }
    }
}
