import MixdownCore
import SwiftUI

/// How far the speech model's download is, with the time left. Shared by Settings and the setup
/// assistant.
struct ModelDownloadProgress: View {
    @Environment(AppEnvironment.self) private var environment
    let progress: Double

    var body: some View {
        ProgressView(value: progress) {
            Text("Downloading \(environment.model.displayName)…")
        } currentValueLabel: {
            Text(ProgressText.detail(progress: progress, remaining: environment.coordinator.timeRemaining))
                .monospacedDigit()
        }
    }
}
