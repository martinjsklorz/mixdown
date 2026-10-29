import SwiftUI

/// Whether Mixdown notifies about calls, and whether it records them without asking. Shared by
/// Settings and the setup assistant.
struct CallsToggles: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        // Off while notifications are, as nothing could be posted.
        Toggle(
            "Notify when calls start and end",
            isOn: Binding(
                get: { environment.preferences.notifiesAboutCalls && environment.preferences.showsNotifications },
                set: { environment.preferences.notifiesAboutCalls = $0 }
            )
        )
        .disabled(!environment.preferences.showsNotifications)
        Toggle(
            "Record calls automatically",
            isOn: Bindable(environment.preferences).recordsCallsAutomatically
        )
    }
}
