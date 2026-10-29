import SwiftUI

/// The setup assistant's page for call detection and notifications.
struct CallsPage: View {
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
                    NotificationsToggle()
                } footer: {
                    Caption(NotificationsToggle.footer)
                }
            }
            .formStyle(.grouped)
        }
    }
}
