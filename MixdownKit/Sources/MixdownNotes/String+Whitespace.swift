extension StringProtocol {
    /// The text on a single line, with each run of whitespace and line breaks made one space and
    /// none at either end. How `MarkdownBlock.plainText(_:)` reads text back, so text written this
    /// way reads back as it was.
    var collapsingWhitespace: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
