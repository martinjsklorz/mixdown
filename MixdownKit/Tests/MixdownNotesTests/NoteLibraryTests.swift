import Foundation
import MixdownCore
import MixdownNotes
import Testing

struct NoteLibraryTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NoteLibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ contents: String, to name: String, in directory: URL) throws {
        try Data(contents.utf8).write(to: directory.appending(path: name, directoryHint: .notDirectory))
    }

    @Test func loadsMarkdownFilesNewestFirst() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = MarkdownNoteWriter(directory: directory)
        let older = NoteFixtures.note(title: "Older")
        var newer = NoteFixtures.note(title: "Newer")
        newer.createdAt += 3600
        _ = try await writer.write(older)
        _ = try await writer.write(newer)
        _ = try await writer.write(newer)
        try write("# Plain", to: "Plain.markdown", in: directory)
        try write("# Ignored", to: "notes.txt", in: directory)
        try write("# Hidden", to: ".hidden.md", in: directory)
        try FileManager.default.createDirectory(
            at: directory.appending(path: "Folder.md", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )

        let notes = try NoteLibrary.loadNotes(in: directory)

        // "Plain" has no `created`, so it's dated now by the file system and comes first.
        #expect(notes.map(\.title) == ["Plain", "Newer", "Newer", "Older"])
    }

    @Test func missingDirectoryHasNoNotes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NoteLibraryTests-missing-\(UUID().uuidString)", directoryHint: .isDirectory)

        #expect(try NoteLibrary.loadNotes(in: directory).isEmpty)
    }

    // MARK: Reloading with a cache

    private func setModificationDate(_ date: Date, of name: String, in directory: URL) throws {
        let path = directory.appending(path: name, directoryHint: .notDirectory).path(percentEncoded: false)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    @Test func cachedReloadPicksUpAddedChangedAndRemovedNotes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("# One", to: "One.md", in: directory)
        try write("# Two", to: "Two.md", in: directory)
        try setModificationDate(.now - 60, of: "Two.md", in: directory)
        var cache = NoteLibrary.Cache()
        #expect(Set(try NoteLibrary.loadNotes(in: directory, cache: &cache).map(\.title)) == ["One", "Two"])

        try write("# Three", to: "Three.md", in: directory)
        try write("# Two, edited", to: "Two.md", in: directory)
        try FileManager.default.removeItem(at: directory.appending(path: "One.md", directoryHint: .notDirectory))

        let titles = try NoteLibrary.loadNotes(in: directory, cache: &cache).map(\.title)
        #expect(Set(titles) == ["Two, edited", "Three"])
    }

    @Test func cachedReloadSkipsFilesThatLookUnchanged() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("# Old", to: "Note.md", in: directory)
        let date = Date.now - 60
        try setModificationDate(date, of: "Note.md", in: directory)
        var cache = NoteLibrary.Cache()
        _ = try NoteLibrary.loadNotes(in: directory, cache: &cache)

        // Same size and date: taken from the cache rather than read again.
        try write("# New", to: "Note.md", in: directory)
        try setModificationDate(date, of: "Note.md", in: directory)
        #expect(try NoteLibrary.loadNotes(in: directory, cache: &cache).map(\.title) == ["Old"])
        // Without the cache it is read.
        #expect(try NoteLibrary.loadNotes(in: directory).map(\.title) == ["New"])
    }

    @Test func cachedReloadOfAnotherFolderHasOnlyItsNotes() throws {
        let first = try makeDirectory()
        let second = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try write("# First", to: "Note.md", in: first)
        try write("# Second", to: "Note.md", in: second)
        var cache = NoteLibrary.Cache()
        _ = try NoteLibrary.loadNotes(in: first, cache: &cache)

        #expect(try NoteLibrary.loadNotes(in: second, cache: &cache).map(\.title) == ["Second"])
        try FileManager.default.removeItem(at: second)
        #expect(try NoteLibrary.loadNotes(in: second, cache: &cache).isEmpty)
        #expect(try NoteLibrary.loadNotes(in: first, cache: &cache).map(\.title) == ["First"])
    }

    // MARK: Renaming

    private func contents(of url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func fileNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
    }

    @Test func renameChangesTitleHeadingAndFileName() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = NoteFixtures.note(title: "Weekly Sync")
        let url = try await MarkdownNoteWriter(directory: directory).write(note)
        let prefix = url.lastPathComponent.prefix("yyyy-MM-dd HHmm ".count)

        let renamed = try NoteLibrary.rename(noteAt: url, to: "  Plan: Q4\nlaunch ")

        #expect(renamed.lastPathComponent == "\(prefix)Plan- Q4 launch.md")
        #expect(try fileNames(in: directory) == [renamed.lastPathComponent])
        let expected = MarkdownNoteRenderer.render(NoteFixtures.note(title: "Plan: Q4 launch"))
        #expect(try contents(of: renamed) == expected)
        #expect(try NoteLibrary.loadNotes(in: directory).map(\.title) == ["Plan: Q4 launch"])
    }

    @Test func renameAvoidsTakenNamesAndKeepsItsOwn() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = MarkdownNoteWriter(directory: directory)
        let first = try await writer.write(NoteFixtures.note(title: "Standup"))
        let second = try await writer.write(NoteFixtures.note(title: "Retro"))

        let renamed = try NoteLibrary.rename(noteAt: second, to: "Standup")
        let again = try NoteLibrary.rename(noteAt: renamed, to: "Standup")

        #expect(renamed.lastPathComponent == first.deletingPathExtension().lastPathComponent + " 2.md")
        #expect(again == renamed)
        #expect(try fileNames(in: directory).count == 2)
    }

    @Test func renameChangesCaseOnly() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("# Standup\n", to: "standup.markdown", in: directory)

        let renamed = try NoteLibrary.rename(
            noteAt: directory.appending(path: "standup.markdown", directoryHint: .notDirectory),
            to: "Standup"
        )

        #expect(try fileNames(in: directory) == ["Standup.markdown"])
        #expect(try contents(of: renamed) == "# Standup\n")
    }

    @Test func renameWithoutFrontmatterChangesTitleHeading() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("Intro\r\n\r\n# Old **Name**\r\n\r\n# Old Name\r\n", to: "Ideas.md", in: directory)

        let renamed = try NoteLibrary.rename(
            noteAt: directory.appending(path: "Ideas.md", directoryHint: .notDirectory),
            to: "New"
        )

        #expect(renamed.lastPathComponent == "New.md")
        #expect(try contents(of: renamed) == "Intro\n\n# New\n\n# Old Name\n")
    }

    @Test func renameAddsFrontmatterWhenTitleCameFromFileName() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("```\n# Ideas\n```\nText", to: "Ideas.md", in: directory)

        let renamed = try NoteLibrary.rename(
            noteAt: directory.appending(path: "Ideas.md", directoryHint: .notDirectory),
            to: "a/b"
        )

        #expect(renamed.lastPathComponent == "a-b.md")
        #expect(try contents(of: renamed) == "---\ntitle: \"a/b\"\n---\n\n```\n# Ideas\n```\nText")
        #expect(try NoteLibrary.loadNotes(in: directory).map(\.title) == ["a/b"])
    }

    @Test func renameReplacesMultiLineTitleAndFillsMissingOne() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("---\ntitle: >\n  Folded\n\n  title\ntags: [x]\n---\nText", to: "Folded.md", in: directory)
        try write("---\ntags: [x]\n---\n# Heading\n", to: "Heading.md", in: directory)

        let folded = try NoteLibrary.rename(
            noteAt: directory.appending(path: "Folded.md", directoryHint: .notDirectory),
            to: "One"
        )
        let heading = try NoteLibrary.rename(
            noteAt: directory.appending(path: "Heading.md", directoryHint: .notDirectory),
            to: "Two"
        )

        #expect(try contents(of: folded) == "---\ntitle: \"One\"\ntags: [x]\n---\nText")
        #expect(try contents(of: heading) == "---\ntitle: \"Two\"\ntags: [x]\n---\n# Two\n")
    }

    @Test func renameToBlankIsUntitled() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await MarkdownNoteWriter(directory: directory).write(NoteFixtures.note())

        let renamed = try NoteLibrary.rename(noteAt: url, to: " \n ")

        #expect(renamed.lastPathComponent.hasSuffix(" Untitled.md"))
        #expect(try NoteLibrary.loadNotes(in: directory).map(\.title) == ["Untitled"])
    }

    // MARK: Restoring

    @Test func restoreMovesTrashedNoteBackUnderItsName() throws {
        let directory = try makeDirectory()
        let trash = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: trash)
        }
        try write("# Standup\n", to: "Standup 14.12.md", in: trash)
        let original = directory.appending(path: "Standup.md", directoryHint: .notDirectory)

        let restored = try NoteLibrary.restore(
            trashedAt: trash.appending(path: "Standup 14.12.md", directoryHint: .notDirectory),
            to: original
        )

        #expect(restored.lastPathComponent == "Standup.md")
        #expect(try fileNames(in: trash).isEmpty)
        #expect(try contents(of: restored) == "# Standup\n")
    }

    @Test func restoreAvoidsNameTakenSince() throws {
        let directory = try makeDirectory()
        let trash = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: trash)
        }
        try write("New", to: "Standup.md", in: directory)
        try write("Old", to: "Standup.md", in: trash)
        let original = directory.appending(path: "Standup.md", directoryHint: .notDirectory)

        let restored = try NoteLibrary.restore(
            trashedAt: trash.appending(path: "Standup.md", directoryHint: .notDirectory),
            to: original
        )

        #expect(restored.lastPathComponent == "Standup 2.md")
        #expect(try contents(of: restored) == "Old")
        #expect(try contents(of: original) == "New")
    }

    @Test func restoreWritesContentsIntoMissingFolder() throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let original = parent.appending(path: "Gone/Standup.markdown", directoryHint: .notDirectory)

        let restored = try NoteLibrary.restore(contents: Data("# Standup".utf8), to: original)

        #expect(restored.lastPathComponent == "Standup.markdown")
        #expect(try contents(of: restored) == "# Standup")
        #expect(try fileNames(in: original.deletingLastPathComponent()) == ["Standup.markdown"])
    }
}
