import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            TranscriptionSettingsView()
                .tabItem { Label("Transcription", systemImage: "waveform") }
        }
        .frame(width: 480)
        // Menu bar agents aren't active when the menu is used, so bring the window forward.
        .onAppear { NSApp.activate() }
    }
}
