import Foundation

/// Finds the notes folder: the one given with `--folder`, else `MIXDOWN_NOTES_FOLDER`, else the
/// one chosen in Mixdown.
enum NotesFolder {
    static let environmentVariable = "MIXDOWN_NOTES_FOLDER"
    static let bundleIdentifier = "app.mixdown.Mixdown"
    /// The app's setting with the folder, a security-scoped bookmark (see `AppSettings`).
    static let bookmarkKey = "notesFolderBookmark"

    static func url(
        option: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws(FolderError) -> URL {
        if let path = option ?? environment[environmentVariable].flatMap({ $0.isEmpty ? nil : $0 }) {
            return URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        let preferences = preferencesFile(home: home)
        let data: Data
        do {
            data = try Data(contentsOf: preferences)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            // Mixdown has never been opened.
            throw .notChosen
        } catch {
            // macOS can ask whether the terminal may read other apps' data, and the answer was no.
            throw .unreadableSetting
        }
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard let bookmark = plist?[bookmarkKey] as? Data else { throw .notChosen }
        guard let path = path(of: bookmark) else { throw .unreadableSetting }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Where the sandboxed app keeps its settings: in its container, not `~/Library/Preferences`,
    /// so `UserDefaults` can't read them from here.
    static func preferencesFile(home: URL) -> URL {
        home.appending(
            path: "Library/Containers/\(bundleIdentifier)/Data/Library/Preferences/\(bundleIdentifier).plist"
        )
    }

    /// The path a bookmark points to, read without resolving it: only the app can resolve its
    /// security-scoped bookmarks.
    private static func path(of bookmark: Data) -> String? {
        #if canImport(Darwin)
        URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path
        #else
        nil
        #endif
    }

    /// Fails unless `url` is a folder that's there, so a drive that isn't connected doesn't look
    /// like a folder without notes.
    static func checkExists(_ url: URL) throws(FolderError) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw .missing(url.path(percentEncoded: false)) }
    }
}

enum FolderError: Error, Equatable, CustomStringConvertible {
    case notChosen
    case unreadableSetting
    case missing(String)

    var description: String {
        switch self {
        case .notChosen:
            "Mixdown has no notes folder yet. Open Mixdown to choose one, or pass --folder or set "
                + "\(NotesFolder.environmentVariable)."
        case .unreadableSetting:
            "Couldn't read Mixdown's notes folder from its settings. Pass --folder or set "
                + "\(NotesFolder.environmentVariable)."
        case .missing(let path):
            "The notes folder \(path) isn't there. Is its drive connected?"
        }
    }
}
