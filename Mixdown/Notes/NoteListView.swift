import AppKit
import MixdownCore
import MixdownNotes
import SwiftUI

/// The sidebar list of notes in sections: today, the previous seven days, then by month.
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
    let actions: NoteActions
    /// Shown instead of the notes when there are none, e.g. an empty or error state.
    @ViewBuilder var footer: Footer
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sections) { section in
                        SectionHeader(title: section.group.title)
                            .transition(.noteRow)
                        ForEach(section.notes) { note in
                            // A button, so VoiceOver announces it and Space or Return opens it
                            // once it has keyboard focus.
                            Button {
                                selection = note.id
                                isFocused = true
                            } label: {
                                NoteRow(
                                    note: note,
                                    dateFormat: section.group.rowDateFormat,
                                    isSelected: showsSelection && note.id == selection
                                )
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
                            .transition(.noteRow)
                        }
                    }
                    footer
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
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
        }
    }

    private func moveSelection(by offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = sections.flatMap { $0.notes.map(\.id) }
        guard !ids.isEmpty else { return .ignored }
        let current = showsSelection ? selection : nil
        let index = current.flatMap(ids.firstIndex(of:)).map { $0 + offset } ?? 0
        let id = ids[min(max(index, 0), ids.count - 1)]
        selection = id
        proxy.scrollTo(id)
        return .handled
    }
}

extension AnyTransition {
    /// A note slides down into its place as it's added and up out of it as it's removed, while
    /// the rows below move to make room or close the gap.
    fileprivate static var noteRow: AnyTransition { .move(edge: .top).combined(with: .opacity) }
}

/// A section's title, like "Today" or "September".
private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.body.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
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
