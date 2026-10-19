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
                    "Show recording in the Dynamic Island",
                    isOn: Binding(
                        get: { environment.showsRecordingInDynamicIsland },
                        set: { environment.setShowsRecordingInDynamicIsland($0) }
                    )
                )
                Group {
                    Picker(
                        "Time",
                        selection: Binding(
                            get: { environment.islandLayout.timeSide },
                            set: { side in environment.setIslandLayout(changedLayout { $0.timeSide = side }) }
                        )
                    ) {
                        ForEach(DynamicIsland.Side.allCases) { side in
                            Text(side.title).tag(side)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle(
                        "Show input levels",
                        isOn: Binding(
                            get: { environment.islandLayout.showsLevels },
                            set: { shows in environment.setIslandLayout(changedLayout { $0.showsLevels = shows }) }
                        )
                    )
                    // Shown off while it can't apply, but remembered for when it can.
                    Toggle(
                        "Show live text",
                        isOn: Binding(
                            get: { environment.islandLayout.showsLiveText && environment.model.isLive },
                            set: { shows in environment.setIslandLayout(changedLayout { $0.showsLiveText = shows }) }
                        )
                    )
                    .disabled(!environment.model.isLive)
                }
                .disabled(!environment.showsRecordingInDynamicIsland)
            } header: {
                Text("Recording")
            } footer: {
                Text(
                    "While recording, the time and input levels appear in a Dynamic Island around the "
                        + "camera notch instead of the time in the menu bar. The levels go on the other side "
                        + "from the time. Without a notch, the island appears at the top center of the "
                        + "screen, and the menu bar keeps the time too, as it does with another display "
                        + "connected. Click the island to open Record.\n\nLive text scrolls the latest "
                        + "words by in one line under the notch. It needs a live model, chosen in "
                        + "Transcription settings."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appearance) { _, appearance in appearance.apply() }
    }

    /// The island's current layout, changed by `change`.
    private func changedLayout(_ change: (inout DynamicIsland.Layout) -> Void) -> DynamicIsland.Layout {
        var layout = environment.islandLayout
        change(&layout)
        return layout
    }
}
