import Foundation
import MixdownCore
import MixdownNotes
import Testing

struct MarkdownNoteWriterTests {
    /// A not-yet-existing directory, so the writer has to create it.
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "MixdownNotesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "Notes", directoryHint: .isDirectory)
    }

    private func datePrefix(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.string(from: date)
    }

    @Test func writesRenderedNoteIntoNewDirectory() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let note = NoteFixtures.note()

        let url = try await MarkdownNoteWriter(directory: directory).write(note)

        #expect(url.lastPathComponent == "\(datePrefix(note.createdAt)) Weekly Sync.md")
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents == MarkdownNoteRenderer.render(note))
    }

    @Test func collisionsGetNumericSuffixAndNeverOverwrite() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let writer = MarkdownNoteWriter(directory: directory)
        let stem = "\(datePrefix(NoteFixtures.createdAt)) Weekly Sync"

        let first = try await writer.write(NoteFixtures.note())
        let second = try await writer.write(NoteFixtures.note(segments: []))
        let third = try await writer.write(NoteFixtures.note())

        #expect(first.lastPathComponent == "\(stem).md")
        #expect(second.lastPathComponent == "\(stem) 2.md")
        #expect(third.lastPathComponent == "\(stem) 3.md")

        // The first file kept its original content.
        let firstContents = try String(contentsOf: first, encoding: .utf8)
        #expect(firstContents == MarkdownNoteRenderer.render(NoteFixtures.note()))

        // No temporary files are left behind.
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(entries.sorted() == ["\(stem) 2.md", "\(stem) 3.md", "\(stem).md"].sorted())
    }

    @Test func sanitizesTitleForFileName() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let note = NoteFixtures.note(title: "  Q3/Q4:\tplan\\review\n ")

        let url = try await MarkdownNoteWriter(directory: directory).write(note)

        let name = url.lastPathComponent
        #expect(name == "\(datePrefix(note.createdAt)) Q3-Q4- plan-review.md")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Notes")
    }

    @Test func capsLongTitles() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let note = NoteFixtures.note(title: String(repeating: "a", count: 300))

        let url = try await MarkdownNoteWriter(directory: directory).write(note)

        let title = url.deletingPathExtension().lastPathComponent
            .dropFirst(datePrefix(note.createdAt).count + 1)
        #expect(title.count == 80)
    }

    /// 80 characters, but 240 bytes in UTF-8, and Hangul triples again when decomposed (as
    /// macOS file names are).
    @Test(arguments: ["会議", "회의"])
    func capsTitlesToFileNameByteLimit(_ word: String) async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let note = NoteFixtures.note(title: String(repeating: word, count: 40))

        let first = try await MarkdownNoteWriter(directory: directory).write(note)
        let second = try await MarkdownNoteWriter(directory: directory).write(note)

        #expect(first.lastPathComponent.hasPrefix("\(datePrefix(note.createdAt)) \(word)\(word)"))
        #expect(second.lastPathComponent.hasSuffix(" 2.md"))
        for url in [first, second] {
            #expect(url.lastPathComponent.decomposedStringWithCanonicalMapping.utf8.count <= 255)
        }
    }

    @Test func emptyTitleFallsBackToUntitled() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let note = NoteFixtures.note(title: " \n\t ")

        let url = try await MarkdownNoteWriter(directory: directory).write(note)

        #expect(url.lastPathComponent == "\(datePrefix(note.createdAt)) Untitled.md")
    }
}
