import Foundation
import UserNotifications
import os

/// Posts Mixdown's notifications, asking for permission the first time. Without it, or with
/// notifications turned off in Settings, nothing is shown. `NotificationResponder`, the
/// notification center's delegate, shows them while Mixdown is in front too.
@MainActor
enum Notifications {
    private static let logger = Logger(subsystem: "app.mixdown", category: "Notifications")
    /// Ids `post` hasn't added yet, as it waits for permission, which can take until the user
    /// answers the system prompt.
    private static var posting: Set<String> = []
    /// Ids of those that `remove(id:)` was called for meanwhile, so they aren't added after all.
    private static var withdrawn: Set<String> = []

    /// - Parameter categoryIdentifier: A category registered with the notification center, for
    ///   buttons such as Restore. `userInfo` goes to whoever handles them.
    static func post(
        title: String,
        body: String,
        categoryIdentifier: String? = nil,
        userInfo: [AnyHashable: Any] = [:],
        id: String = UUID().uuidString
    ) async {
        posting.insert(id)
        defer {
            posting.remove(id)
            withdrawn.remove(id)
        }
        // Checked before asking, so turning them off in Settings also stops the permission prompt.
        guard AppSettings().showsNotifications else { return }
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert]) else {
                logger.info("Not posting “\(title, privacy: .public)”: notifications are turned off for Mixdown")
                return
            }
            guard !withdrawn.contains(id) else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let categoryIdentifier { content.categoryIdentifier = categoryIdentifier }
            content.userInfo = userInfo
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            // Withdrawn while it was being added.
            if withdrawn.contains(id) {
                remove(id: id)
                return
            }
            // macOS shows it from here on, unless it holds it back, e.g. during a Focus.
            logger.info("Posted “\(title, privacy: .public)”")
        } catch {
            logger.error("Couldn't post notification: \(error.localizedDescription)")
        }
    }

    /// `post`, without waiting for it: `remove(id:)` takes the notification away, or keeps it
    /// from showing, from the moment this returns.
    static func send(
        title: String,
        body: String,
        categoryIdentifier: String? = nil,
        userInfo: [String: String] = [:],
        id: String = UUID().uuidString
    ) {
        posting.insert(id)
        Task {
            await post(title: title, body: body, categoryIdentifier: categoryIdentifier, userInfo: userInfo, id: id)
        }
    }

    /// Takes a notification posted with `id` out of Notification Center, or stops it from showing.
    /// One still waiting to be posted isn't posted.
    static func remove(id: String) {
        if posting.contains(id) { withdrawn.insert(id) }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// Whether Mixdown may notify: `.notDetermined` until the user answers the system prompt.
    nonisolated static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Shows the system prompt if the user hasn't answered it yet, ahead of the first
    /// notification. Returns whether Mixdown may notify.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        } catch {
            logger.error("Couldn't ask for permission to notify: \(error.localizedDescription)")
            return false
        }
    }
}
