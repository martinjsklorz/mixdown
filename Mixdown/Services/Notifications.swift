import Foundation
import UserNotifications
import os

/// Posts Mixdown's notifications, asking for permission the first time. Without it, or with
/// notifications turned off in Settings, nothing is shown. `NotificationResponder`, the
/// notification center's delegate, shows them while Mixdown is in front too.
@MainActor
enum Notifications {
    private static let logger = Logger(subsystem: "app.mixdown", category: "Notifications")

    /// - Parameter categoryIdentifier: A category registered with the notification center, for
    ///   buttons such as Restore. `userInfo` goes to whoever handles them.
    static func post(
        title: String,
        body: String,
        categoryIdentifier: String? = nil,
        userInfo: [AnyHashable: Any] = [:],
        id: String = UUID().uuidString
    ) async {
        // Checked before asking, so turning them off in Settings also stops the permission prompt.
        guard AppSettings().showsNotifications else { return }
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert]) else {
                logger.info("Not posting “\(title, privacy: .public)”: notifications are turned off for Mixdown")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let categoryIdentifier { content.categoryIdentifier = categoryIdentifier }
            content.userInfo = userInfo
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            // macOS shows it from here on, unless it holds it back, e.g. during a Focus.
            logger.info("Posted “\(title, privacy: .public)”")
        } catch {
            logger.error("Couldn't post notification: \(error.localizedDescription)")
        }
    }

    /// Takes a notification posted with `id` out of Notification Center, or stops it from showing.
    static func remove(id: String) {
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
