import SwiftUI
import UserNotifications

/// The setup assistant's page for call detection and notifications.
struct CallsPage: View {
    @AppStorage(AppSettings.Key.showsNotifications) private var showsNotifications = true
    @State private var notificationAccess: UNAuthorizationStatus?

    var body: some View {
        SetupPage(
            title: "Calls and Notifications",
            systemImage: "phone.bubble",
            detail: "Mixdown notices when Zoom, Teams, FaceTime or a browser starts using the "
                + "microphone, and can offer to record the call."
        ) {
            Form {
                Section {
                    CallsToggles()
                } footer: {
                    Caption(
                        "Without automatic recording, a notification asks whether to record. Recording "
                            + "a call turns on system audio."
                    )
                }

                Section {
                    Toggle("Show notifications", isOn: $showsNotifications)
                    if showsNotifications {
                        LabeledContent("Permission") {
                            notificationAccessControl
                        }
                    }
                } footer: {
                    Caption(
                        "Notifications ask about calls, say when a note is ready, and offer Restore after "
                            + "deleting a note."
                    )
                }
            }
            .formStyle(.grouped)
        }
        .task { await refresh() }
        // The user can change it in System Settings, so re-read on coming back from there.
        .onWindowBecomesKey { Task { await refresh() } }
    }

    @ViewBuilder
    private var notificationAccessControl: some View {
        switch notificationAccess {
        case .notDetermined:
            Button("Allow…") {
                Task {
                    await Notifications.requestAuthorization()
                    await refresh()
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

    private func refresh() async {
        notificationAccess = await Notifications.authorizationStatus()
    }
}
