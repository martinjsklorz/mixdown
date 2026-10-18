import MixdownCore
import SwiftUI

/// The status item: an icon reflecting the coordinator's phase, plus the time left while a
/// model downloads or a recording is transcribed, or the time elapsed while recording (unless the
/// Dynamic Island shows it).
struct MenuBarLabel: View {
    let environment: AppEnvironment

    private var coordinator: RecordingCoordinator { environment.coordinator }
    private var hasSilentInput: Bool { !coordinator.silentDevices.isEmpty }

    var body: some View {
        // Whole seconds recorded so far, while recording; `nil` while the Dynamic Island shows them,
        // which also spares the label redrawing every second.
        let recordingElapsed = environment.showsRecordingInDynamicIsland ? nil : environment.recordingElapsed
        let phase = coordinator.phase
        let remaining = coordinator.timeRemaining
        HStack(spacing: 4) {
            Self.icon(for: phase)
            if case .preparingModel(let progress) = phase {
                Text(ProgressText.compact(progress: progress, remaining: remaining))
                    .monospacedDigit()
            } else if case .transcribing(let progress) = phase {
                Text(ProgressText.compact(progress: progress, remaining: remaining))
                    .monospacedDigit()
            } else if case .recording = phase, let recordingElapsed {
                Text(Self.elapsedText(recordingElapsed))
                    .monospacedDigit()
            }
            // Visible with the menu closed, for recordings started and left in the background.
            if hasSilentInput {
                Image(systemName: "speaker.slash")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Self.accessibilityLabel(for: phase, remaining: remaining, elapsed: recordingElapsed)
                + (hasSilentInput ? ", no sound from an input" : "")
        )
    }

    /// The app's mark while idle; a status symbol otherwise.
    static func icon(for phase: RecordingCoordinator.Phase) -> Image {
        switch phase {
        case .idle: Image("MenuBarIcon").renderingMode(.template)
        case .preparingModel: Image(systemName: "arrow.down.circle")
        case .startingCapture: Image(systemName: "record.circle")
        case .recording: Image(systemName: "record.circle.fill")
        case .transcribing, .summarizing: Image(systemName: "ellipsis.circle")
        case .failed: Image(systemName: "exclamationmark.triangle")
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
            "Mixdown, downloading model, \(ProgressText.detail(progress: progress, remaining: remaining))"
        case .startingCapture: "Mixdown, starting to record"
        case .recording:
            if let elapsed {
                "Mixdown, recording, \(Duration.seconds(elapsed).formatted(.units(width: .wide)))"
            } else {
                "Mixdown, recording"
            }
        case .transcribing(let progress):
            "Mixdown, transcribing, \(ProgressText.detail(progress: progress, remaining: remaining))"
        case .summarizing: "Mixdown, summarizing"
        case .failed: "Mixdown, error"
        }
    }
}
