import MixdownNotes
import SwiftUI

/// A rendered preview of one note. The text is read-only; `DetailToolbar` pins, renames, copies,
/// summarizes again, shares and trashes the note. Scrolls to a line picked in Spotlight and highlights it for a
/// moment.
struct NoteDetailView: View {
    let note: NoteDocument
    @Environment(MainNavigation.self) private var navigation
    @Environment(AppEnvironment.self) private var environment
    /// The block `MainNavigation.blockToShow` asked for, while it's highlighted. Kept with its
    /// note, as this view stays when another note is selected.
    @State private var highlight: MainNavigation.NoteBlock?

    var body: some View {
        let blocks = note.displayBlocks()

        ScrollViewReader { proxy in
            content(blocks)
                // Start each note at the top.
                .id(note.id)
                .task(id: navigation.blockToShow) { takeBlockToShow() }
                .task(id: highlight) { await scrollToHighlight(using: proxy) }
        }
        .navigationTitle(note.title)
    }

    private func content(_ blocks: [MarkdownBlock]) -> some View {
        ScrollView {
            // Lazy, because a long meeting transcript has hundreds of paragraphs.
            LazyVStack(alignment: .leading, spacing: 0) {
                NoteMetadataView(note: note)
                    .padding(.bottom, 16)
                if environment.library.summarizingNoteID == note.id {
                    Label {
                        Text("Summarizing again…")
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
                }
                // In place of the note's `## Talk Time` table, which `displayBlocks()` leaves out.
                if let timeline = note.talkTimeline {
                    TalkTimelineView(timeline: timeline)
                        .padding(.bottom, 16)
                }
                Divider()
                    .padding(.bottom, 20)

                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    MarkdownBlockView(block: block)
                        .background {
                            if highlight == MainNavigation.NoteBlock(noteID: note.id, index: index) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentColor.opacity(0.2))
                                    .padding(-6)
                            }
                        }
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
    }

    /// Highlights the block `MainNavigation.blockToShow` asks for, if it's in this note.
    private func takeBlockToShow() {
        guard let block = navigation.blockToShow, block.noteID == note.id else { return }
        navigation.blockToShow = nil
        highlight = block
    }

    /// Scrolls the highlighted block into the middle, then fades the highlight out.
    private func scrollToHighlight(using proxy: ScrollViewProxy) async {
        guard let highlight, highlight.noteID == note.id else { return }
        // Once the blocks are laid out, so there's somewhere to scroll to.
        await Task.yield()
        withAnimation { proxy.scrollTo(highlight.index, anchor: .center) }
        // Cut short when another note is selected, so the highlight doesn't stay for when it's back.
        try? await Task.sleep(for: .seconds(2))
        guard self.highlight == highlight else { return }
        withAnimation(.easeOut(duration: 0.6)) { self.highlight = nil }
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
