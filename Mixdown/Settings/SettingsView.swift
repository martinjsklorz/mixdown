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
            SummarySettingsView()
                .tabItem { tabLabel(.summary) }
                .tag(MainNavigation.SettingsTab.summary)
            TranslationSettingsView()
                .tabItem { tabLabel(.translation) }
                .tag(MainNavigation.SettingsTab.translation)
            VocabularySettingsView()
                .tabItem { tabLabel(.vocabulary) }
                .tag(MainNavigation.SettingsTab.vocabulary)
            NotificationsSettingsView()
                .tabItem { tabLabel(.notifications) }
                .tag(MainNavigation.SettingsTab.notifications)
            DesignSettingsView()
                .tabItem { tabLabel(.design) }
                .tag(MainNavigation.SettingsTab.design)
        }
        .frame(width: 600, height: height(for: navigation.settingsTab))
    }

    /// Tall enough for each tab without scrolling, including the warnings General and Notifications
    /// can show.
    private func height(for tab: MainNavigation.SettingsTab) -> CGFloat {
        switch tab {
        case .general: 620
        case .recording: 540
        case .transcription: 460
        case .summary: 280
        case .translation: 360
        case .vocabulary: 520
        case .notifications: 590
        case .design: 570
        }
    }

    private func tabLabel(_ tab: MainNavigation.SettingsTab) -> some View {
        Label(tab.rawValue, systemImage: tab.systemImage)
    }
}
