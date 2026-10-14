import MixdownCore
import SwiftUI

/// The status item: an icon reflecting the coordinator's phase, plus the time left while a
/// model downloads.
struct MenuBarLabel: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        let phase = coordinator.phase
        let remaining = coordinator.preparationTimeRemaining
        HStack(spacing: 4) {
            Image(systemName: Self.symbolName(for: phase))
            if case .preparingModel(let progress) = phase {
                Text(DownloadProgressText.compact(progress: progress, remaining: remaining))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: phase, remaining: remaining))
    }

    static func symbolName(for phase: RecordingCoordinator.Phase) -> String {
        switch phase {
        case .idle: "waveform"
        case .preparingModel: "arrow.down.circle"
        case .recording: "record.circle.fill"
        case .transcribing: "ellipsis.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    static func accessibilityLabel(for phase: RecordingCoordinator.Phase, remaining: TimeInterval?) -> String {
        switch phase {
        case .idle: "Mixdown"
        case .preparingModel(let progress):
            "Mixdown, downloading model, \(DownloadProgressText.detail(progress: progress, remaining: remaining))"
        case .recording: "Mixdown, recording"
        case .transcribing: "Mixdown, transcribing"
        case .failed: "Mixdown, error"
        }
    }
}
