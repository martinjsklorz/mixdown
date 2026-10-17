import MixdownNotes
import SwiftUI

/// One Markdown block, styled after Apple Notes. Notes and Help are rendered with it.
struct MarkdownBlockView: View {
    let block: MarkdownBlock

    /// The space above `block` when it follows `previous`. List items sit closer together than
    /// other blocks.
    static func spacing(between previous: MarkdownBlock, and block: MarkdownBlock) -> CGFloat {
        switch (previous, block) {
        case (.listItem, .listItem): 4
        case (_, .heading): 20
        default: 12
        }
    }

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
