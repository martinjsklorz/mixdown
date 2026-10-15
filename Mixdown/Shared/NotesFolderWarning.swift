/// Wording for when there's no notes folder to save to, shared by the Record view, the menu and
/// Settings. Recording waits until there is one.
enum NotesFolderWarning {
    /// "Choose a Notes Folder"; `nil` while the folder is available.
    static func title(for status: NotesFolderStore.Status) -> String? {
        switch status {
        case .notChosen: "Choose a Notes Folder"
        case .unavailable: "Notes Folder Not Available"
        case .available: nil
        }
    }

    /// What's wrong and what to do about it; `nil` while the folder is available.
    static func message(for status: NotesFolderStore.Status, hasLegacyNotes: Bool) -> String? {
        switch status {
        case .notChosen:
            "Mixdown saves each recording as a Markdown file in a folder you choose, such as "
                + "Documents › Mixdown."
                + (hasLegacyNotes ? " The notes you've already recorded move there too." : "")
        case .unavailable:
            "Can't reach \(folder(status)). If it's on a drive that isn't connected, connect it, "
                + "or choose another folder."
        case .available:
            nil
        }
    }

    /// Short form for the menu: "Choose a notes folder to start recording".
    static func menuTitle(for status: NotesFolderStore.Status) -> String? {
        switch status {
        case .notChosen: "Choose a notes folder to start recording"
        case .unavailable: "Can't reach \(folder(status))"
        case .available: nil
        }
    }

    /// "the folder “Mixdown”", or "your notes folder" if its name isn't known.
    private static func folder(_ status: NotesFolderStore.Status) -> String {
        status.name.map { "the folder “\($0)”" } ?? "your notes folder"
    }
}
