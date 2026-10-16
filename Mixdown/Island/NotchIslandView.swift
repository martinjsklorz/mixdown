import MixdownCore
import SwiftUI

/// The notch island's content: the recording time left of the notch, a waveform per input right
/// of it, on black that runs into the notch.
struct NotchIslandView: View {
    /// How far the island reaches out on either side of the notch.
    static let wingWidth: CGFloat = 80

    let environment: AppEnvironment
    /// Left empty in the middle, behind the notch. Zero on screens without one.
    let notchWidth: CGFloat
    let openRecorder: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ElapsedWing(environment: environment)
                .frame(width: Self.wingWidth)
            Color.clear
                .frame(width: notchWidth)
            LevelsWing(coordinator: environment.coordinator)
                .frame(width: Self.wingWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture { openRecorder() }
        .help("Open Record")
    }
}

/// A pulsing red dot and the time recorded so far.
private struct ElapsedWing: View {
    let environment: AppEnvironment

    var body: some View {
        let elapsed = environment.recordingElapsed ?? 0
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
            Text(MenuBarLabel.elapsedText(elapsed))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, \(Duration.seconds(elapsed).formatted(.units(width: .wide)))")
    }
}

/// A waveform per input, like the music one in the iPhone's Dynamic Island: its last few levels as
/// rounded bars, newest on the right, that shrink to dots in silence. An input that stays silent
/// turns orange. With two inputs, the microphone is on the left.
private struct LevelsWing: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        let silent = Set(coordinator.silentDevices.map(\.id))

        HStack(spacing: 8) {
            ForEach(coordinator.selectedDevices) { device in
                Waveform(coordinator: coordinator, deviceID: device.id, isSilent: silent.contains(device.id))
                    .help(device.name)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(device.name) level")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 12)
    }
}

/// One input's recent levels as bars.
private struct Waveform: View {
    static let barCount = 5
    static let barWidth: CGFloat = 3
    static let maxBarHeight: CGFloat = 16

    let coordinator: RecordingCoordinator
    let deviceID: String
    let isSilent: Bool
    @State private var history = Array(repeating: 0.0, count: barCount)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(history.indices, id: \.self) { index in
                Capsule()
                    .frame(width: Self.barWidth, height: max(Self.barWidth, history[index] * Self.maxBarHeight))
            }
        }
        .frame(height: Self.maxBarHeight)
        .foregroundStyle(isSilent ? Color.orange : Color.white.opacity(0.75))
        .animation(.easeOut(duration: 0.1), value: history)
        // Sampled on a clock rather than on each new level, so the bars keep moving (to dots) while
        // an input delivers the same level, such as exact silence.
        .task {
            while !Task.isCancelled {
                history.removeFirst()
                history.append(coordinator.inputLevels[deviceID]?.meterValue ?? 0)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
