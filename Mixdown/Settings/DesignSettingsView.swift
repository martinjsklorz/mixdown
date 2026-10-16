import SwiftUI

/// How Mixdown looks, including while it works.
struct DesignSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @AppStorage(AppSettings.Key.appearance) private var appearance: Appearance = .auto

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Auto follows Appearance in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Show recording in the notch",
                    isOn: Binding(
                        get: { environment.showsRecordingInNotch },
                        set: { environment.setShowsRecordingInNotch($0) }
                    )
                )
            } header: {
                Text("Recording")
            } footer: {
                Text(
                    "While recording, the time and input levels appear around the camera notch, like the "
                        + "Dynamic Island, instead of the time in the menu bar. Without a notch, they appear "
                        + "at the top center of the screen. Click them to open Record."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appearance) { _, appearance in appearance.apply() }
    }
}
