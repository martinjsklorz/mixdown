import Foundation
import UserNotifications
import os

/// Posts Mixdown's notifications, asking for permission the first time. Without it, nothing is
/// shown. `NotificationRouter`, the notification center's delegate, shows them while Mixdown is in
/// front too.
@MainActor
enum Notifications {
    private static let logger = Logger(subsystem: "app.mixdown", category: "Notifications")

    /// - Parameter categoryIdentifier: A category registered with `NotificationRouter`, for
    ///   buttons such as Restore. `userInfo` goes to its handler.
    static func post(
        title: String,
        body: String,
        categoryIdentifier: String? = nil,
        userInfo: [String: String] = [:],
        id: String = UUID().uuidString
    ) async {
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
}

/// A click on one of Mixdown's notifications or one of its buttons.
struct NotificationResponse: Sendable {
    let notificationID: String
    /// The button's identifier, or `UNNotificationDefaultActionIdentifier` for the notification.
    let actionIdentifier: String
    let userInfo: [String: String]
}

/// The delegate of the app's `UNUserNotificationCenter`. Has Mixdown's notifications shown while
/// it's in front too, and hands clicks to the handler registered for the notification's category.
///
/// Created at launch, by the first `register`, so it also handles notifications from an earlier run.
@MainActor
final class NotificationRouter: NSObject {
    static let shared = NotificationRouter()

    private var categories: [String: UNNotificationCategory] = [:]
    private var handlers: [String: (NotificationResponse) -> Void] = [:]

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Adds `category`, so notifications posted with it get its buttons, and calls `handler` when
    /// one of them, or the notification, is clicked.
    func register(_ category: UNNotificationCategory, handler: @escaping (NotificationResponse) -> Void) {
        categories[category.identifier] = category
        handlers[category.identifier] = handler
        // This replaces the categories registered so far, so it has to include all of them.
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories.values))
    }

    private func handle(_ response: NotificationResponse, category: String) {
        handlers[category]?(response)
    }
}

extension NotificationRouter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Shown while Mixdown is in front too: that's when Restore is most useful, and when
        // Copy Transcript happens.
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let request = response.notification.request
        var userInfo: [String: String] = [:]
        for (key, value) in request.content.userInfo {
            if let key = key as? String, let value = value as? String { userInfo[key] = value }
        }
        let routed = NotificationResponse(
            notificationID: request.identifier,
            actionIdentifier: response.actionIdentifier,
            userInfo: userInfo
        )
        await handle(routed, category: request.content.categoryIdentifier)
    }
}
