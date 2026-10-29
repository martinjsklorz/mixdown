import SwiftUI

/// How Mixdown looks, including while it works.
struct DesignSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    private var preferences: Preferences { environment.preferences }
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
                Caption("Auto follows Appearance in System Settings.")
            }

            Section {
                Toggle(
                    "Show recording in the Dynamic Island",
                    isOn: Bindable(preferences).showsRecordingInDynamicIsland
                )
                Group {
                    Picker(
                        "Time",
                        selection: Bindable(preferences).islandLayout.timeSide
                    ) {
                        ForEach(DynamicIsland.Side.allCases) { side in
                            Text(side.title).tag(side)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle(
                        "Show input levels",
                        isOn: Bindable(preferences).islandLayout.showsLevels
                    )
                    // Shown off while it can't apply, but remembered for when it can.
                    Toggle(
                        "Show live text",
                        isOn: Binding(
                            get: { preferences.islandLayout.showsLiveText && environment.model.isLive },
                            set: { preferences.islandLayout.showsLiveText = $0 }
                        )
                    )
                    .disabled(!environment.model.isLive)
                    Toggle(
                        "Show talk share",
                        isOn: Binding(
                            get: { preferences.islandLayout.showsTalkShare && preferences.measuresTalkTime },
                            set: { preferences.islandLayout.showsTalkShare = $0 }
                        )
                    )
                    .disabled(!preferences.measuresTalkTime)
                }
                .disabled(!preferences.showsRecordingInDynamicIsland)
            } header: {
                Text("Recording")
            } footer: {
                Caption(
                    "While recording, the time and input levels appear in a Dynamic Island around the "
                        + "camera notch instead of the time in the menu bar. The levels go on the other side "
                        + "from the time. Without a notch, the island appears at the top center of the "
                        + "screen, and the menu bar keeps the time too, as it does with another display "
                        + "connected. Click the island to open Record. The island and what drops down under it don't "
                        + "show when you share your screen or take a screenshot.\n\nLive text scrolls the latest "
                        + "words by in one line under the notch, translated if the live text is. It needs a "
                        + "live model, chosen in Transcription settings.\n\nWhile you record both a microphone and system audio, "
                        + "a ring next to the time shows how much of the talking was yours, in white, "
                        + "and the others', in grey. It needs talk time, turned on in Recording settings."
                )
            }
        }
        .formStyle(.grouped)
        .onChange(of: appearance) { _, appearance in appearance.apply() }
    }
}
