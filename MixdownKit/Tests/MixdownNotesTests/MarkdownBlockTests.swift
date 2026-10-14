import MixdownNotes
import Testing

struct MarkdownBlockTests {
    @Test func parsesRenderedNoteBody() {
        let markdown = """
            # Weekly Sync

            ## Transcript

            **[00:00:00] Speaker 1:** Hello everyone.

            **[00:01:05] Speaker 2:** Next topic.
            """

        #expect(
            MarkdownBlock.parse(markdown) == [
                .heading(level: 1, text: "Weekly Sync"),
                .heading(level: 2, text: "Transcript"),
                .paragraph("**[00:00:00] Speaker 1:** Hello everyone."),
                .paragraph("**[00:01:05] Speaker 2:** Next topic."),
            ]
        )
    }

    @Test func headings() {
        let markdown = """
            ### Closed ###
            ####### Too deep
            #tag

            Setext
            ======
            Two
            ---
            """

        #expect(
            MarkdownBlock.parse(markdown) == [
                .heading(level: 3, text: "Closed"),
                .paragraph("####### Too deep\n#tag"),
                .heading(level: 1, text: "Setext"),
                .heading(level: 2, text: "Two"),
            ]
        )
    }

    @Test func paragraphsKeepLineBreaksAndEndAtBlankLines() {
        let markdown = "First line\n  second line\n\n\nNext paragraph\r\nsame paragraph"

        #expect(
            MarkdownBlock.parse(markdown) == [
                .paragraph("First line\nsecond line"),
                .paragraph("Next paragraph\nsame paragraph"),
            ]
        )
    }

    @Test func listsWithNesting() {
        let markdown = """
            - one
            * two
              continued
              - nested
                1. deeper
            + back
            10) ten
            -not a list
            """

        #expect(
            MarkdownBlock.parse(markdown) == [
                .listItem(number: nil, depth: 0, text: "one"),
                .listItem(number: nil, depth: 0, text: "two\ncontinued"),
                .listItem(number: nil, depth: 1, text: "nested"),
                .listItem(number: 1, depth: 2, text: "deeper"),
                .listItem(number: nil, depth: 0, text: "back"),
                .listItem(number: 10, depth: 0, text: "ten\n-not a list"),
            ]
        )
    }

    @Test func listDepthResetsAfterOtherBlocks() {
        let markdown = """
            - top
              - nested

            # Heading
              - indented, but a new list
            """

        #expect(
            MarkdownBlock.parse(markdown) == [
                .listItem(number: nil, depth: 0, text: "top"),
                .listItem(number: nil, depth: 1, text: "nested"),
                .heading(level: 1, text: "Heading"),
                .listItem(number: nil, depth: 0, text: "indented, but a new list"),
            ]
        )
    }

    @Test func quotesAndRules() {
        let markdown = """
            > quoted
            >continued
            lazy
            ***
            - - -
            ___
            """

        #expect(
            MarkdownBlock.parse(markdown) == [
                .quote("quoted\ncontinued\nlazy"),
                .rule,
                .rule,
                .rule,
            ]
        )
    }

    @Test func fencedCodeKeepsContentVerbatim() {
        let markdown = """
            ```swift
            let x = 1

            # not a heading
            ```
            ~~~~
            - not a list
            ~~~
            ~~~~
            ```
            unclosed
            """

        #expect(
            MarkdownBlock.parse(markdown) == [
                .code(language: "swift", text: "let x = 1\n\n# not a heading"),
                .code(language: nil, text: "- not a list\n~~~"),
                .code(language: nil, text: "unclosed"),
            ]
        )
    }

    @Test func emptyInput() {
        #expect(MarkdownBlock.parse("").isEmpty)
        #expect(MarkdownBlock.parse("\n  \n").isEmpty)
    }

    @Test func plainTextStripsInlineMarkdown() {
        let text = MarkdownBlock.plainText("**[00:00:00] Speaker 1:** Hello  _there_\nfriend")

        #expect(text == "[00:00:00] Speaker 1: Hello there friend")
    }
}
