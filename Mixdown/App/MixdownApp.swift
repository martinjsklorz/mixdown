import SwiftUI

@main
struct MixdownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()
    @State private var navigation = MainNavigation()

    var body: some Scene {
        // Recording and notes. Opens at launch; `AppDelegate` reopens it when the Dock icon is
        // clicked.
        Window("Mixdown", id: MainView.windowID) {
            MainView()
                .environment(environment)
                .environment(navigation)
                .capturesOpenWindow(for: appDelegate)
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
                .capturesOpenWindow(for: appDelegate)
        } label: {
            MenuBarLabel(
                coordinator: environment.coordinator,
                recordingElapsed: environment.recordingElapsed
            )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(environment)
                .environment(navigation)
        }
    }
}
