import SwiftUI

/// The Settings window. Its tab is shared so other views can open it at a particular one.
struct SettingsView: View {
    @Environment(MainNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation

        TabView(selection: $navigation.settingsTab) {
            GeneralSettingsView()
                .tabItem { tabLabel(.general) }
                .tag(MainNavigation.SettingsTab.general)
            RecordingSettingsView()
                .tabItem { tabLabel(.recording) }
                .tag(MainNavigation.SettingsTab.recording)
            TranscriptionSettingsView()
                .tabItem { tabLabel(.transcription) }
                .tag(MainNavigation.SettingsTab.transcription)
            NotificationsSettingsView()
                .tabItem { tabLabel(.notifications) }
                .tag(MainNavigation.SettingsTab.notifications)
            DesignSettingsView()
                .tabItem { tabLabel(.design) }
                .tag(MainNavigation.SettingsTab.design)
        }
        .frame(width: 520, height: height(for: navigation.settingsTab))
    }

    /// Tall enough for each tab without scrolling, including the warnings General can show.
    private func height(for tab: MainNavigation.SettingsTab) -> CGFloat {
        switch tab {
        case .general: 440
        case .recording: 420
        case .transcription: 630
        case .notifications: 400
        case .design: 160
        }
    }

    private func tabLabel(_ tab: MainNavigation.SettingsTab) -> some View {
        Label(tab.rawValue, systemImage: tab.systemImage)
    }
}
