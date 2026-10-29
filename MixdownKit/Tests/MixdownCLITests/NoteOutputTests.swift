import Foundation
import MixdownNotes
import Testing

@testable import MixdownCLI

struct NoteOutputTests {
    private let directory = URL(filePath: "/Users/me/Notes", directoryHint: .isDirectory)
    private let berlin = TimeZone(identifier: "Europe/Berlin") ?? .gmt

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        return calendar
    }

    private static let contents = """
        ---
        title: "Weekly Sync"
        created: 2026-10-24T09:30:00+02:00
        duration: 754
        sources: ["MacBook Pro Microphone", "System Audio"]
        source_kinds: [microphone, systemAudio]
        trigger: automatic
        call: true
        speakers: ["Me", "Others"]
        pinned: true
        tags: [mixdown]
        ---

        # Weekly Sync

        ## Summary

        The release moves to Friday.

        ### Key Points

        - Friday it is.

        ### Action Items

        - [ ] Others update the release notes.

        ## Transcript

        **[00:00:00] Me:** Morning, everyone.

        ```
        ## Not a heading
        ```

        **[00:00:03] Others:** Let's look at the release plan.
        """

    private func note(folder: String? = "Clients/Acme") -> NoteDocument {
        let path = [folder, "2026-10-24 0930 Weekly Sync.md"].compactMap { $0 }.joined(separator: "/")
        var note = NoteDocument(
            url: directory.appending(path: path, directoryHint: .notDirectory),
            contents: Self.contents,
            fileDate: .distantPast
        )
        note.folder = folder
        return note
    }

    @Test func listsDateLengthTitleAndFile() {
        let lines = NoteOutput.lines(for: [note()], calendar: calendar)
        #expect(lines == "2026-10-24 09:30  13 min       Weekly Sync  (Clients/Acme/2026-10-24 0930 Weekly Sync.md)")
    }

    @Test func putsTheMatchingLineUnderTheNote() {
        let note = note(folder: nil)
        let lines = NoteOutput.lines(
            for: [note],
            matches: [note.id: "The release moves to Friday."],
            calendar: calendar
        )
        #expect(lines.hasSuffix("(2026-10-24 0930 Weekly Sync.md)\n    The release moves to Friday."))
    }

    @Test func roundsDurations() {
        #expect(NoteOutput.formatted(duration: 44.6) == "45 s")
        #expect(NoteOutput.formatted(duration: 59.4) == "59 s")
        #expect(NoteOutput.formatted(duration: 754) == "13 min")
        #expect(NoteOutput.formatted(duration: 3_900) == "1 h 05 min")
        #expect(NoteOutput.formatted(duration: 36_300).count <= NoteOutput.durationWidth)
    }

    @Test func givesTheFrontmatterInJSON() throws {
        let fields = NoteOutput.Fields(note(), timeZone: berlin)
        #expect(fields.created == "2026-10-24T09:30:00+02:00")
        #expect(fields.relativePath == "Clients/Acme/2026-10-24 0930 Weekly Sync.md")
        #expect(fields.path == "/Users/me/Notes/Clients/Acme/2026-10-24 0930 Weekly Sync.md")
        #expect(fields.duration == 754)
        #expect(fields.sources == ["MacBook Pro Microphone", "System Audio"])
        #expect(fields.trigger == "automatic")
        #expect(fields.call && fields.pinned)
        #expect(fields.speakers == ["Me", "Others"])

        let json = NoteOutput.json(fields)
        #expect(json.contains(#""relative_path" : "Clients/Acme/2026-10-24 0930 Weekly Sync.md""#))
        // Fields a note doesn't have are left out.
        #expect(!json.contains("template"))
        #expect(!json.contains("match"))
    }

    @Test func printsASectionWithItsSubsections() throws {
        let body = note().body
        let summary = try NoteOutput.section("summary", in: body)
        #expect(summary.hasPrefix("The release moves to Friday."))
        #expect(summary.hasSuffix("- [ ] Others update the release notes."))
        #expect(try NoteOutput.section("Action Items", in: body) == "- [ ] Others update the release notes.")
    }

    @Test func skipsHeadingsInCodeBlocks() throws {
        let transcript = try NoteOutput.section("Transcript", in: note().body)
        #expect(transcript.hasSuffix("Let's look at the release plan."))
        #expect(throws: SectionError.self) { try NoteOutput.section("Not a heading", in: note().body) }
    }

    @Test func namesTheSectionsANoteHas() {
        #expect(
            throws: SectionError(name: "Moments", available: ["Summary", "Key Points", "Action Items", "Transcript"])
        ) {
            try NoteOutput.section("Moments", in: note().body)
        }
    }
}
