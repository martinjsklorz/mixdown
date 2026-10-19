import MixdownNotes
import SwiftUI

/// A rendered preview of one note. The text is read-only; the toolbar pins, renames, copies,
/// shares and trashes the note.
struct NoteDetailView: View {
    let note: NoteDocument
    let actions: NoteActions

    var body: some View {
        let blocks = note.displayBlocks()

        ScrollView {
            // Lazy, because a long meeting transcript has hundreds of paragraphs.
            LazyVStack(alignment: .leading, spacing: 0) {
                NoteMetadataView(note: note)
                    .padding(.bottom, 16)
                // In place of the note's `## Talk Time` table, which `displayBlocks()` leaves out.
                if let timeline = note.talkTimeline {
                    TalkTimelineView(timeline: timeline)
                        .padding(.bottom, 16)
                }
                Divider()
                    .padding(.bottom, 20)

                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    MarkdownBlockView(block: block)
                        .padding(
                            .top,
                            index == 0 ? 0 : MarkdownBlockView.spacing(between: blocks[index - 1], and: block)
                        )
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
        }
        // Start each note at the top.
        .id(note.id)
        .navigationTitle(note.title)
        // Editing and sharing in separate groups; otherwise they'd all share one glass background.
        .toolbar {
            ToolbarItemGroup {
                Button(
                    note.isPinned ? "Unpin" : "Pin",
                    systemImage: note.isPinned ? "pin.slash" : "pin"
                ) { actions.togglePinned(note) }
                Button("Copy Transcript", systemImage: "doc.on.doc") { NoteActions.copyTranscript(of: note) }
                Button("Rename", systemImage: "pencil") { actions.rename(note) }
                Button("Delete", systemImage: "trash") { actions.moveToTrash(note) }
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                ShareLink(item: note.url, preview: SharePreview(note.title))
            }
        }
    }
}

/// When the note was recorded, how long it runs and what it was recorded from, each under its
/// own label. Side by side, or stacked when the window is too narrow.
private struct NoteMetadataView: View {
    let note: NoteDocument

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 32) { fields }
            VStack(alignment: .leading, spacing: 12) { fields }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var fields: some View {
        field("Date", systemImage: "calendar") {
            // Two-digit hours keep the width steady between notes ("02:35", not "2:35").
            let date = note.createdAt.formatted(date: .long, time: .omitted)
            let time = note.createdAt.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
            Text("\(date) at \(time)")
                .monospacedDigit()
        }
        if let duration = note.duration, duration >= 1 {
            field("Duration", systemImage: "clock") {
                Text(
                    Duration.seconds(duration.rounded())
                        .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
                )
                .monospacedDigit()
            }
        }
        if !note.sources.isEmpty {
            field(note.sources.count == 1 ? "Input" : "Inputs", systemImage: "mic") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(note.sources.indices, id: \.self) { Text(note.sources[$0]) }
                }
            }
        }
    }

    private func field(
        _ title: String,
        systemImage: String,
        @ViewBuilder value: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            value()
                .font(.callout)
        }
    }
}
