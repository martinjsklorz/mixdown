import AppKit
import MixdownCore
import MixdownNotes

/// The standard About panel, with the disk space Mixdown's models and notes take up below the
/// version. Measured each time it's opened.
@MainActor
enum AboutPanel {
    static func show(notesFolder: NotesFolderStore.Status) {
        Task {
            // Off the main actor: a big notes folder takes a moment to walk.
            let lines = await Task.detached { storageLines(notesFolder: notesFolder) }.value
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let credits = NSAttributedString(
                string: lines.joined(separator: "\n"),
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            )
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        }
    }

    /// "Models: 4.2 GB" and "Notes: 1.3 MB (128 notes)".
    private nonisolated static func storageLines(notesFolder: NotesFolderStore.Status) -> [String] {
        let models = ModelDirectory.diskUsage
        let modelsLine = models.fileCount == 0 ? "Models: none downloaded" : "Models: \(size(models.bytes))"

        let notesLine: String
        switch notesFolder {
        case .notChosen:
            notesLine = "Notes: no folder chosen"
        case .unavailable:
            notesLine = "Notes: folder not available"
        case .available(let directory):
            let notes = NoteLibrary.diskUsage(in: directory)
            let count = notes.fileCount == 1 ? "1 note" : "\(notes.fileCount) notes"
            notesLine = notes.fileCount == 0 ? "Notes: none yet" : "Notes: \(size(notes.bytes)) (\(count))"
        }
        return [modelsLine, notesLine]
    }

    /// As Finder shows it, e.g. "4.2 GB".
    private nonisolated static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
