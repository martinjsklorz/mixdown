import SwiftUI

/// How Mixdown looks.
struct DesignSettingsView: View {
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
        }
        .formStyle(.grouped)
        .onChange(of: appearance) { _, appearance in appearance.apply() }
    }
}
