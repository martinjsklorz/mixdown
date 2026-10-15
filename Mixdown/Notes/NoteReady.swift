import AppKit
import MixdownNotes
import UserNotifications

/// Posts "Note Ready" once a recording has been transcribed and saved, with buttons to open the
/// note in Mixdown or show its file in Finder. Clicking the notification itself opens the note.
///
/// `NotificationResponder` hands it the buttons, on notifications from an earlier run, too.
@MainActor
final class NoteReady {
    nonisolated static let categoryIdentifier = "noteReady"
    private nonisolated static let openAction = "open"
    private nonisolated static let showInFinderAction = "showInFinder"
    private nonisolated static let pathKey = "path"

    /// The Open and Show in Finder buttons, registered by `NotificationResponder`.
    static let category = UNNotificationCategory(
        identifier: categoryIdentifier,
        actions: [
            UNNotificationAction(identifier: openAction, title: "Open", options: [.foreground]),
            UNNotificationAction(identifier: showInFinderAction, title: "Show in Finder"),
        ],
        intentIdentifiers: []
    )

    private let navigation: MainNavigation

    init(navigation: MainNavigation) {
        self.navigation = navigation
    }

    /// Posts the notification for the note just saved at `url`, with the note's title as its body.
    func notify(noteAt url: URL) async {
        // The file name if the note can't be read back, which is unlikely right after writing it.
        let title =
            (try? Data(contentsOf: url)).map {
                NoteDocument(url: url, contents: String(decoding: $0, as: UTF8.self), fileDate: .now).title
            } ?? url.deletingPathExtension().lastPathComponent
        await Notifications.post(
            title: "Note Ready",
            body: title,
            categoryIdentifier: Self.categoryIdentifier,
            userInfo: [Self.pathKey: url.path(percentEncoded: false)]
        )
    }

    /// Shows the note in the main window, opening it if it's closed.
    private func open(_ url: URL) {
        navigation.showNote(at: url)
    }

    /// Selects the note's file in Finder, or opens its folder if the file has been renamed or
    /// moved since.
    private func showInFinder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

extension NoteReady {
    /// Handles a click on a notification of `category` or one of its buttons.
    nonisolated func respond(to response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo[Self.pathKey] as? String else { return }
        let url = URL(filePath: path)
        switch response.actionIdentifier {
        case Self.openAction, UNNotificationDefaultActionIdentifier:
            await open(url)
        case Self.showInFinderAction:
            await showInFinder(url)
        default:
            break
        }
    }
}
