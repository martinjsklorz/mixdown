import Foundation

/// Reads the YAML frontmatter at the start of a Markdown note: just enough YAML for the fields
/// notes have, leniently, so notes edited by hand or by other apps still read.
enum Frontmatter {
    /// Splits off a leading `---` … `---` block and reads its top-level `key: value` fields.
    /// Values are kept as written, with the lines they continue on; decode them with
    /// `yamlScalar(_:)` or `yamlSequence(_:)`.
    static func split(_ contents: String) -> (fields: [String: String], body: String) {
        let lines = normalizedLines(contents)
        guard let end = Self.end(of: lines) else { return ([:], lines.joined(separator: "\n")) }

        var fields: [String: String] = [:]
        for index in 1..<end {
            guard let key = Self.key(of: lines[index]) else { continue }
            fields[key] = value(of: lines[index..<fieldEnd(after: index, in: lines, end: end)])
        }
        return (fields, lines[(end + 1)...].joined(separator: "\n"))
    }

    /// `contents` with `\n` line endings and without a byte order mark.
    static func normalized(_ contents: String) -> String {
        var text = contents.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    /// `contents`' lines after `normalized(_:)`.
    static func normalizedLines(_ contents: String) -> [String] {
        normalized(contents).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The lines of the top-level `key` field in the frontmatter closed at `end`, including the
    /// lines a multi-line value continues on, up to the next key.
    static func fieldLines(_ key: String, in lines: [String], end: Int) -> Range<Int>? {
        guard let index = lines[1..<end].firstIndex(where: { Self.key(of: $0) == key }) else { return nil }
        return index..<fieldEnd(after: index, in: lines, end: end)
    }

    /// The value of the field on the first of `lines`, with the lines it continues on, as written:
    /// the first line's text after the colon, then the other lines, without trailing blank lines.
    static func value(of lines: ArraySlice<String>) -> String {
        guard let first = lines.first, let colon = first.firstIndex(of: ":") else { return "" }
        let value = first[first.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        var rest = lines.dropFirst()
        while rest.last?.allSatisfy(\.isWhitespace) == true { rest = rest.dropLast() }
        return ([value] + rest).joined(separator: "\n")
    }

    /// The index after the lines the field on line `index` continues on: indented and blank
    /// lines, and the `- item` lines of a block sequence, which YAML allows without indentation.
    private static func fieldEnd(after index: Int, in lines: [String], end: Int) -> Int {
        lines[(index + 1)..<end].firstIndex { line in
            guard let first = line.first else { return false }
            return !first.isWhitespace && !isSequenceItem(line)
        } ?? end
    }

    /// Whether `line` is an item of a YAML block sequence, `- item` or a bare `-`.
    private static func isSequenceItem<Line: StringProtocol>(_ line: Line) -> Bool {
        line.first == "-" && line.dropFirst().first.map(\.isWhitespace) ?? true
    }

    /// The index of the line closing the frontmatter, if `lines` start with frontmatter.
    static func end<Line: StringProtocol>(of lines: [Line]) -> Int? {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        return lines.dropFirst().firstIndex {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line == "---" || line == "..."
        }
    }

    /// The key of a top-level `key: value` frontmatter line.
    static func key<Line: StringProtocol>(of line: Line) -> String? {
        guard let first = line.first, !first.isWhitespace, first != "#", !isSequenceItem(line),
            let colon = line.firstIndex(of: ":")
        else { return nil }
        return line[..<colon].trimmingCharacters(in: .whitespaces)
    }

    /// The value of a YAML scalar: quotes removed and escapes resolved, comments dropped.
    /// An unterminated quoted value is kept as written. Only the first line is read.
    static func yamlScalar(_ raw: String) -> String {
        let raw = String(raw.prefix { $0 != "\n" })
        if raw.first == "\"" || raw.first == "'" {
            return quotedScalar(raw[...])?.value ?? raw
        }
        guard let comment = raw.range(of: " #") else { return raw }
        return raw[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
    }

    /// The items of a YAML sequence, or `nil` if `raw` isn't one: a flow sequence like
    /// `["a", 'b', c]`, or a block sequence with an item per `- item` line, the way Obsidian
    /// writes lists. Either may span lines. Empty items are dropped.
    static func yamlSequence(_ raw: String) -> [String]? {
        let lines = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if raw.first == "[" { return yamlFlowSequence(lines.joined(separator: " ")) }
        // A block sequence's items start on the line after the key.
        guard raw.first == "\n" else { return nil }

        var items: [String] = []
        for line in lines where !line.isEmpty && !line.hasPrefix("#") {
            if isSequenceItem(line) {
                items.append(line.dropFirst().trimmingCharacters(in: .whitespaces))
            } else if let last = items.indices.last {
                // An item continued on the next line, folded into one like YAML does.
                items[last] += (items[last].isEmpty ? "" : " ") + line
            } else {
                return nil
            }
        }
        return items.isEmpty ? nil : items.map(yamlScalar).filter { !$0.isEmpty }
    }

    /// The items of a YAML flow sequence like `["a", 'b', c]`, or `nil` if `raw` isn't a
    /// complete one. Empty items are dropped.
    private static func yamlFlowSequence(_ raw: String) -> [String]? {
        guard raw.first == "[" else { return nil }
        var items: [String] = []
        var rest = raw.dropFirst()
        while true {
            rest = rest.drop(while: \.isWhitespace)
            guard let first = rest.first else { return nil }
            // Also ends `[]` and a trailing comma.
            if first == "]" { return items }
            let item: String
            if first == "\"" || first == "'" {
                guard let quoted = quotedScalar(rest) else { return nil }
                item = quoted.value
                rest = rest[quoted.end...]
            } else {
                let end = rest.firstIndex { $0 == "," || $0 == "]" } ?? rest.endIndex
                item = rest[..<end].trimmingCharacters(in: .whitespaces)
                rest = rest[end...]
            }
            if !item.isEmpty { items.append(item) }
            rest = rest.drop(while: \.isWhitespace)
            if rest.first == "," {
                rest = rest.dropFirst()
            } else if rest.first != "]" {
                return nil
            }
        }
    }

    /// The value of the single- or double-quoted scalar `raw` starts with, and the index after
    /// its closing quote. `nil` if `raw` doesn't start with a quote or it's unterminated.
    private static func quotedScalar(_ raw: Substring) -> (value: String, end: Substring.Index)? {
        switch raw.first {
        case "\"":
            var isEscaped = false
            for index in raw.indices.dropFirst() {
                if isEscaped {
                    isEscaped = false
                } else if raw[index] == "\\" {
                    isEscaped = true
                } else if raw[index] == "\"" {
                    let value = unescapeDoubleQuoted(raw[raw.index(after: raw.startIndex)..<index])
                    return (value, raw.index(after: index))
                }
            }
            return nil
        case "'":
            // The only escape in single quotes is `''` for a quote.
            var value = ""
            var index = raw.index(after: raw.startIndex)
            while index < raw.endIndex {
                let character = raw[index]
                index = raw.index(after: index)
                guard character == "'" else {
                    value.append(character)
                    continue
                }
                guard index < raw.endIndex, raw[index] == "'" else { return (value, index) }
                value.append("'")
                index = raw.index(after: index)
            }
            return nil
        default:
            return nil
        }
    }

    /// Resolves the escapes `MarkdownNoteRenderer.yamlQuoted(_:)` writes, plus the other common
    /// YAML ones. Unknown escapes keep the escaped character.
    static func unescapeDoubleQuoted(_ value: Substring) -> String {
        var result = String.UnicodeScalarView()
        var scalars = value.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\\", let escaped = scalars.next() else {
                result.append(scalar)
                continue
            }
            switch escaped {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "0": result.append("\0")
            case "x", "u", "U":
                let length = escaped == "x" ? 2 : escaped == "u" ? 4 : 8
                var hex = String.UnicodeScalarView()
                for _ in 0..<length {
                    if let digit = scalars.next() { hex.append(digit) }
                }
                if let code = UInt32(String(hex), radix: 16), let decoded = Unicode.Scalar(code) {
                    result.append(decoded)
                }
            default:
                result.append(escaped)
            }
        }
        return String(result)
    }

    /// An ISO 8601 date-time, with or without fractional seconds, or a plain `yyyy-MM-dd` date.
    static func date(fromYAML value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        // Only matters for date-only values: midnight local time, not UTC.
        formatter.timeZone = .current
        let variants: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime],
            [.withInternetDateTime, .withFractionalSeconds],
            [.withFullDate],
        ]
        for options in variants {
            formatter.formatOptions = options
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
