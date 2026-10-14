import MixdownCore
import SwiftUI

/// The status item: an icon reflecting the coordinator's phase, plus the time left while a
/// model downloads or the time elapsed while recording.
struct MenuBarLabel: View {
    let coordinator: RecordingCoordinator
    /// Whole seconds recorded so far, while recording.
    let recordingElapsed: Int?

    var body: some View {
        let phase = coordinator.phase
        let remaining = coordinator.preparationTimeRemaining
        HStack(spacing: 4) {
            Image(systemName: Self.symbolName(for: phase))
            if case .preparingModel(let progress) = phase {
                Text(DownloadProgressText.compact(progress: progress, remaining: remaining))
                    .monospacedDigit()
            } else if case .recording = phase, let recordingElapsed {
                Text(Self.elapsedText(recordingElapsed))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: phase, remaining: remaining, elapsed: recordingElapsed))
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

    /// "0:16", "12:05", "1:02:03".
    static func elapsedText(_ seconds: Int) -> String {
        let duration = Duration.seconds(seconds)
        return seconds >= 3600
            ? duration.formatted(.time(pattern: .hourMinuteSecond))
            : duration.formatted(.time(pattern: .minuteSecond))
    }

    static func accessibilityLabel(
        for phase: RecordingCoordinator.Phase,
        remaining: TimeInterval?,
        elapsed: Int?
    ) -> String {
        switch phase {
        case .idle: "Mixdown"
        case .preparingModel(let progress):
            "Mixdown, downloading model, \(DownloadProgressText.detail(progress: progress, remaining: remaining))"
        case .recording:
            if let elapsed {
                "Mixdown, recording, \(Duration.seconds(elapsed).formatted(.units(width: .wide)))"
            } else {
                "Mixdown, recording"
            }
        case .transcribing: "Mixdown, transcribing"
        case .failed: "Mixdown, error"
        }
    }
}
