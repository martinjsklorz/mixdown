import SwiftUI

/// Whether Mixdown notifies about calls, and whether it records them without asking. Shared by
/// Settings and the setup assistant.
struct CallsToggles: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Toggle(
            "Notify when calls start and end",
            isOn: Binding(
                get: { environment.preferences.notifiesAboutCalls },
                set: { environment.preferences.notifiesAboutCalls = $0 }
            )
        )
        Toggle(
            "Record calls automatically",
            isOn: Binding(
                get: { environment.preferences.recordsCallsAutomatically },
                set: { environment.preferences.recordsCallsAutomatically = $0 }
            )
        )
    }
}
