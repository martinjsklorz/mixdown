import Foundation
import UserNotifications
import os

/// Posts Mixdown's notifications, asking for permission the first time. Without it, nothing is
/// shown. `NotificationResponder`, the notification center's delegate, shows them while Mixdown is
/// in front too.
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
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert]) else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let categoryIdentifier { content.categoryIdentifier = categoryIdentifier }
            content.userInfo = userInfo
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        } catch {
            logger.error("Couldn't post notification: \(error.localizedDescription)")
        }
    }
}
