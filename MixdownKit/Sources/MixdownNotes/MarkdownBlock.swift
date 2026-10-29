import Foundation

/// A block-level element of a Markdown document. Inline Markdown (emphasis, links, code spans)
/// stays in the text; render it with `MarkdownBlock.inline(_:)`.
///
/// Covers the blocks notes realistically contain. Anything else (tables, HTML) becomes a
/// paragraph and shows as written. Line breaks inside a block are kept, like Obsidian does.
public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `number` is `nil` for bullets. `depth` is the nesting level, starting at 0.
    case listItem(number: Int?, depth: Int, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case rule

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var parser = Parser()
        // `\r\n` is a single `Character`, so it has to go before splitting on `\n`.
        for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            parser.consume(String(line))
        }
        return parser.finish()
    }

    /// Inline Markdown as an attributed string, keeping line breaks. Falls back to the raw text.
    public static func inline(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    /// Inline Markdown reduced to plain text on a single line.
    public static func plainText(_ markdown: String) -> String {
        String(inline(markdown).characters).collapsingWhitespace
    }
}

// MARK: - Parser

/// Line-based parser for a CommonMark subset. Lists don't nest other blocks, and a blank line
/// always ends the current block. Its line classification is internal so renaming can find a
/// note's title heading.
struct Parser {
    private enum OpenBlock {
        case paragraph([String])
        case listItem(number: Int?, depth: Int, lines: [String])
        case quote([String])
        case code(fence: Substring, language: String?, lines: [String])
    }

    private var blocks: [MarkdownBlock] = []
    /// The block following lines may be added to.
    private var open: OpenBlock?
    /// Indents of the enclosing list items, outermost first. Determines an item's depth.
    private var listIndents: [Int] = []

    mutating func consume(_ line: String) {
        if case .code(let fence, let language, var lines) = open {
            if Self.isClosingFence(line, for: fence) {
                close()
            } else {
                lines.append(line)
                open = .code(fence: fence, language: language, lines: lines)
            }
            return
        }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            close()
            return
        }

        if let (fence, language) = Self.openingFence(trimmed) {
            start(.code(fence: fence, language: language, lines: []))
        } else if let (level, text) = Self.atxHeading(trimmed) {
            start(nil)
            blocks.append(.heading(level: level, text: text))
        } else if case .paragraph(let lines) = open, let level = Self.setextLevel(trimmed) {
            open = nil
            blocks.append(.heading(level: level, text: lines.joined(separator: "\n")))
        } else if Self.isRule(trimmed) {
            start(nil)
            blocks.append(.rule)
        } else if let (indent, number, text) = Self.listItem(line) {
            close()
            open = .listItem(number: number, depth: depth(forIndent: indent), lines: [text])
        } else if trimmed.hasPrefix(">") {
            var content = trimmed.dropFirst()
            if content.first == " " { content = content.dropFirst() }
            if case .quote(var lines) = open {
                lines.append(String(content))
                open = .quote(lines)
            } else {
                start(.quote([String(content)]))
            }
        } else {
            // Plain text continues the open block (CommonMark's "lazy continuation").
            switch open {
            case .paragraph(var lines):
                lines.append(trimmed)
                open = .paragraph(lines)
            case .listItem(let number, let depth, var lines):
                lines.append(trimmed)
                open = .listItem(number: number, depth: depth, lines: lines)
            case .quote(var lines):
                lines.append(trimmed)
                open = .quote(lines)
            case .code, nil:
                start(.paragraph([trimmed]))
            }
        }
    }

    mutating func finish() -> [MarkdownBlock] {
        close()
        return blocks
    }

    /// Closes the open block and any list, then opens `block`.
    private mutating func start(_ block: OpenBlock?) {
        close()
        listIndents.removeAll()
        open = block
    }

    private mutating func close() {
        switch open {
        case .paragraph(let lines):
            blocks.append(.paragraph(lines.joined(separator: "\n")))
        case .listItem(let number, let depth, let lines):
            blocks.append(.listItem(number: number, depth: depth, text: lines.joined(separator: "\n")))
        case .quote(let lines):
            blocks.append(.quote(lines.joined(separator: "\n")))
        case .code(_, let language, let lines):
            blocks.append(.code(language: language, text: lines.joined(separator: "\n")))
        case nil:
            break
        }
        open = nil
    }

    /// Items indented further than the previous one nest below it; items at an earlier indent
    /// go back to that level.
    private mutating func depth(forIndent indent: Int) -> Int {
        while let last = listIndents.last, last > indent { listIndents.removeLast() }
        if listIndents.last != indent { listIndents.append(indent) }
        return listIndents.count - 1
    }

    // MARK: Line classification

    /// `## Title ##` → (2, "Title"). A `#` must be followed by a space, so `#tag` is not a heading.
    static func atxHeading(_ trimmed: String) -> (Int, String)? {
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        if let closing = text.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            text = text[..<closing.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        return (level, text)
    }

    /// A line of `=` (level 1) or `-` (level 2) under a paragraph.
    private static func setextLevel(_ trimmed: String) -> Int? {
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    /// Three or more `-`, `*` or `_`, optionally separated by spaces.
    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// `- item`, `* item`, `+ item`, `1. item` or `1) item`, with the indent in columns (a tab is 4).
    private static func listItem(_ line: String) -> (Int, Int?, String)? {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.dropFirst(leading.count)

        let number: Int?
        let markerLength: Int
        if let first = rest.first, "-*+".contains(first) {
            number = nil
            markerLength = 1
        } else {
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            guard (1...9).contains(digits.count),
                let delimiter = rest.dropFirst(digits.count).first,
                delimiter == "." || delimiter == ")"
            else { return nil }
            number = Int(digits)
            markerLength = digits.count + 1
        }

        let text = rest.dropFirst(markerLength)
        guard text.isEmpty || text.first?.isWhitespace == true else { return nil }
        return (indent, number, text.trimmingCharacters(in: .whitespaces))
    }

    /// ```` ```swift ```` → ("```", "swift").
    static func openingFence(_ trimmed: String) -> (Substring, String?)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let fence = trimmed.prefix(while: { $0 == first })
        guard fence.count >= 3 else { return nil }
        let info = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
        // Backtick fences can't have backticks in their info string; it would be inline code.
        if first == "`", info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init)
        return (fence, language)
    }

    static func isClosingFence(_ line: String, for fence: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let mark = fence.first else { return false }
        return trimmed.count >= fence.count && trimmed.allSatisfy { $0 == mark }
    }
}
