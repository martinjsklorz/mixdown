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

        Window("Notes", id: NotesView.windowID) {
            NotesView()
                .environment(environment)
        }
        .defaultSize(width: 900, height: 600)
        // Only opened from the menu; a menu bar app shouldn't pop up a window at launch or login.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(environment)
        }
    }
}
