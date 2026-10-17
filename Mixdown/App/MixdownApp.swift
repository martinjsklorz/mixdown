import SwiftUI

@main
struct MixdownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment: AppEnvironment
    @State private var navigation: MainNavigation

    init() {
        let settings = AppSettings()
        let navigation = MainNavigation()
        // Written down, so choosing a folder in the assistant and quitting doesn't count as having
        // set up before the assistant existed.
        let needsSetup = settings.needsSetup
        settings.needsSetup = needsSetup
        navigation.isShowingSetup = needsSetup
        _navigation = State(initialValue: navigation)
        _environment = State(initialValue: AppEnvironment(navigation: navigation, settings: settings))
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

        Window("Mixdown Help", id: HelpView.windowID) {
            HelpView()
                .environment(navigation)
        }
        .defaultSize(width: 820, height: 600)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // Opened from the Help menu, so it isn't listed in the Window menu too.
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(environment)
                .environment(navigation)
        }
    }
}
