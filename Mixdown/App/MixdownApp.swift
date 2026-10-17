import SwiftUI

@main
struct MixdownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment: AppEnvironment
    @State private var navigation: MainNavigation

    init() {
        let navigation = MainNavigation()
        _navigation = State(initialValue: navigation)
        _environment = State(initialValue: AppEnvironment(navigation: navigation))
    }

    var body: some Scene {
        // Recording and notes. Opens at launch; `AppDelegate` reopens it when the Dock icon is
        // clicked.
        Window("Mixdown", id: MainView.windowID) {
            MainView()
                .environment(environment)
                .environment(navigation)
                .capturesOpenWindow(for: appDelegate, navigation: navigation)
        }
        .defaultSize(width: 960, height: 620)
        .defaultPosition(.center)
        // Always open at launch, even if it was closed at quit, so the Dock icon can reopen it.
        .restorationBehavior(.disabled)
        .keyboardShortcut("0")
        .commands {
            MixdownCommands(environment: environment, navigation: navigation)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(environment)
                .environment(navigation)
                .capturesOpenWindow(for: appDelegate, navigation: navigation)
        } label: {
            // Reads the environment itself: read here, the elapsed time ticking every second
            // would rebuild every scene.
            MenuBarLabel(environment: environment)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(environment)
                .environment(navigation)
        }
    }
}
