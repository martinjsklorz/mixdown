import Foundation
import MixdownNotes
import Observation
import UserNotifications
import os

/// Moves notes to the Trash and puts them back. Each note moved to the Trash gets a notification
/// with a Restore button, shown even while Mixdown is in front so it works like an undo.
///
/// `NotificationResponder` hands it Restore, on notifications from an earlier run, too.
@MainActor @Observable
final class NoteTrash {
    /// A note put back from the Trash, for the main window to show. A new value per restore, so
    /// putting the same note back twice still counts as a change.
    struct Restored: Equatable {
        let url: URL
        let id = UUID()
    }

    private(set) var lastRestored: Restored?

    /// The contents of recently trashed notes by notification, in case the Trash can't be read
    /// from the sandbox. Only for this run; older notifications rely on the file in the Trash.
    @ObservationIgnored private var contents: [(notificationID: String, data: Data)] = []

    private static let maxKeptContents = 20
    nonisolated static let categoryIdentifier = "noteTrashed"
    private nonisolated static let restoreAction = "restore"
    private static let logger = Logger(subsystem: "app.mixdown", category: "NoteTrash")

    /// The Restore button, registered by `NotificationResponder`.
    static let category = UNNotificationCategory(
        identifier: categoryIdentifier,
        actions: [UNNotificationAction(identifier: restoreAction, title: "Restore")],
        intentIdentifiers: []
    )

    /// Moves the note to the Trash, then posts a notification offering to restore it, unless
    /// notifications are turned off. Asks for permission to notify the first time.
    func moveToTrash(_ note: NoteDocument) throws {
        let data = try? Data(contentsOf: note.url)
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: note.url, resultingItemURL: &trashedURL)
        guard let trashedURL = trashedURL as URL? else { return }

        let trashed = TrashedNote(title: note.title, originalURL: note.url, trashedURL: trashedURL)
        let notificationID = UUID().uuidString
        if let data {
            contents.append((notificationID, data))
            contents.removeFirst(max(0, contents.count - Self.maxKeptContents))
        }
        Task {
            await Notifications.post(
                title: "Note Moved to Trash",
                body: trashed.title,
                categoryIdentifier: Self.categoryIdentifier,
                userInfo: trashed.userInfo,
                id: notificationID
            )
        }
    }

    /// Puts the note back where it was, from the Trash or else from the contents kept when it
    /// was trashed. Notifies if neither works.
    private func restore(_ trashed: TrashedNote, notificationID: String) {
        let data = contents.first { $0.notificationID == notificationID }?.data
        contents.removeAll { $0.notificationID == notificationID }
        do {
            let url: URL
            do {
                url = try NoteLibrary.restore(trashedAt: trashed.trashedURL, to: trashed.originalURL)
            } catch {
                guard let data else { throw error }
                Self.logger.error("Couldn't move note out of the Trash: \(error.localizedDescription)")
                url = try NoteLibrary.restore(contents: data, to: trashed.originalURL)
                try? FileManager.default.removeItem(at: trashed.trashedURL)
            }
            lastRestored = Restored(url: url)
        } catch {
            Self.logger.error("Couldn't restore note: \(error.localizedDescription)")
            Task {
                await Notifications.post(
                    title: "Couldn't Restore Note",
                    body: "“\(trashed.title)” is still in the Trash. \(error.localizedDescription)"
                )
            }
        }
    }
}

extension NoteTrash {
    /// Handles a button on a notification of `category`.
    nonisolated func respond(to response: UNNotificationResponse) async {
        let request = response.notification.request
        guard response.actionIdentifier == Self.restoreAction,
            let trashed = TrashedNote(userInfo: request.content.userInfo)
        else { return }
        await restore(trashed, notificationID: request.identifier)
    }
}

/// Where a trashed note came from and went, kept in its notification's `userInfo`.
private struct TrashedNote: Sendable {
    let title: String
    let originalURL: URL
    let trashedURL: URL

    init(title: String, originalURL: URL, trashedURL: URL) {
        self.title = title
        self.originalURL = originalURL
        self.trashedURL = trashedURL
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let title = userInfo["title"] as? String,
            let originalPath = userInfo["originalPath"] as? String,
            let trashedPath = userInfo["trashedPath"] as? String
        else { return nil }
        self.title = title
        originalURL = URL(filePath: originalPath)
        trashedURL = URL(filePath: trashedPath)
    }

    var userInfo: [AnyHashable: Any] {
        [
            "title": title,
            "originalPath": originalURL.path(percentEncoded: false),
            "trashedPath": trashedURL.path(percentEncoded: false),
        ]
    }
}
