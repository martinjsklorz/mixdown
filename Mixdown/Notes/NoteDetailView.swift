import AppKit
import MixdownNotes
import SwiftUI

/// A read-only, rendered preview of one note.
struct NoteDetailView: View {
    let note: NoteDocument

    var body: some View {
        let blocks = note.displayBlocks()

        ScrollView {
            // Lazy, because a long meeting transcript has hundreds of paragraphs.
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 20)

                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    MarkdownBlockView(block: block)
                        .padding(.top, index == 0 ? 0 : Self.spacing(between: blocks[index - 1], and: block))
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
        }
        // Start each note at the top.
        .id(note.id)
        .navigationTitle(note.title)
        .toolbar {
            ToolbarItemGroup {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([note.url])
                }
                Button("Open in Default App", systemImage: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(note.url)
                }
            }
        }
    }

    /// "October 14, 2026 at 3:52 AM · 12 min, 34 sec · MacBook Pro Microphone"
    private var details: String {
        var parts = [note.createdAt.formatted(date: .long, time: .shortened)]
        if let duration = note.duration, duration >= 1 {
            parts.append(
                Duration.seconds(duration.rounded())
                    .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
            )
        }
        if let source = note.source { parts.append(source) }
        return parts.joined(separator: " · ")
    }

    /// List items sit closer together than other blocks.
    private static func spacing(between previous: MarkdownBlock, and block: MarkdownBlock) -> CGFloat {
        switch (previous, block) {
        case (.listItem, .listItem): 4
        case (_, .heading): 20
        default: 12
        }
    }
}

/// One Markdown block, styled after Apple Notes.
private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownBlock.inline(text))
                .font(Self.headingFont(level))
        case .paragraph(let text):
            Text(MarkdownBlock.inline(text))
                .lineSpacing(3)
        case .listItem(let number, let depth, let text):
            listItem(number: number, text: text)
                .padding(.leading, CGFloat(depth) * 20)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tertiary)
                    .frame(width: 3)
                Text(MarkdownBlock.inline(text))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(_, let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }

    /// Bullets, numbers, and checkboxes for `[ ]` / `[x]` task items.
    private func listItem(number: Int?, text: String) -> some View {
        let checkboxes = [("[ ] ", "square"), ("[x] ", "checkmark.square"), ("[X] ", "checkmark.square")]
        var text = text
        var marker = Text(number.map { "\($0)." } ?? "•")
        if let (prefix, symbol) = checkboxes.first(where: { text.hasPrefix($0.0) }) {
            text.removeFirst(prefix.count)
            marker = Text(Image(systemName: symbol))
        }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(MarkdownBlock.inline(text))
                .lineSpacing(3)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title.bold()
        case 2: .title2.bold()
        case 3: .title3.bold()
        default: .headline
        }
    }
}
