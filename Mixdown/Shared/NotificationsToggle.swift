import SwiftUI
import UserNotifications

/// Show notifications, and while it's on, whether macOS lets Mixdown notify: a button to ask, or
/// to open System Settings where it was turned off. Shared by Settings and the setup assistant.
struct NotificationsToggle: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var access: UNAuthorizationStatus?

    /// What notifications are for, for the footer under the toggle.
    static let footer =
        "Notifications ask about calls, say when a note is ready, ask whether you're still recording, "
        + "confirm copying a transcript, report notes the vocabulary couldn't correct, and offer Restore "
        + "after deleting a note."

    var body: some View {
        @Bindable var preferences = environment.preferences
        Toggle("Show notifications", isOn: $preferences.showsNotifications)
        if preferences.showsNotifications {
            LabeledContent("Permission") {
                accessControl
            }
            // The user can change it in System Settings, so it's read again on showing it and on
            // coming back to a window of ours, such as from System Settings.
            .onAppear { refresh() }
            .onWindowBecomesKey { refresh() }
        }
    }

    @ViewBuilder
    private var accessControl: some View {
        switch access {
        case .notDetermined:
            Button("Allow…") {
                Task {
                    await Notifications.requestAuthorization()
                    access = await Notifications.authorizationStatus()
                }
            }
        case .denied:
            HStack {
                Text("Turned off")
                    .foregroundStyle(.red)
                Button("Open System Settings") { SystemSettings.open(.notifications) }
            }
        case nil:
            EmptyView()
        default:
            DoneLabel("Allowed")
        }
    }

    private func refresh() {
        Task { access = await Notifications.authorizationStatus() }
    }
}
