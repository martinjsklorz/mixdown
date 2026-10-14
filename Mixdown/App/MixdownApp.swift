import SwiftUI

@main
struct MixdownApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(environment)
        } label: {
            MenuBarLabel(coordinator: environment.coordinator)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(environment)
        }
    }
}
