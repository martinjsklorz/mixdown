import MixdownCore
import SwiftUI

/// The notch island's content: the recording time on one side of the notch and, unless turned off,
/// a waveform per input on the other, on black that runs into the notch.
struct NotchIslandView: View {
    /// How far the island reaches out on either side of the notch.
    static let wingWidth: CGFloat = 80

    let environment: AppEnvironment
    /// Left empty in the middle, behind the notch. Zero on screens without one.
    let notchWidth: CGFloat
    let layout: NotchIsland.Layout
    let openRecorder: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            wing(on: .left)
            Color.clear
                .frame(width: notchWidth)
            wing(on: .right)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture { openRecorder() }
        .help("Open Record")
    }

    @ViewBuilder
    private func wing(on side: NotchIsland.Side) -> some View {
        if side == layout.timeSide {
            ElapsedWing(environment: environment, side: side)
                .frame(width: Self.wingWidth)
        } else if layout.showsLevels {
            LevelsWing(coordinator: environment.coordinator, side: side)
                .frame(width: Self.wingWidth)
        }
    }
}

extension View {
    /// Aligns a wing's content to the island's outer edge on `side`, leaving more room there than
    /// next to the notch.
    fileprivate func wingAlignment(_ side: NotchIsland.Side) -> some View {
        frame(maxWidth: .infinity, alignment: side == .left ? .leading : .trailing)
            .padding(side == .left ? .leading : .trailing, 12)
            .padding(side == .left ? .trailing : .leading, 6)
    }
}

/// A pulsing red dot and the time recorded so far.
private struct ElapsedWing: View {
    let environment: AppEnvironment
    let side: NotchIsland.Side

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
        .wingAlignment(side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, \(Duration.seconds(elapsed).formatted(.units(width: .wide)))")
    }
}

/// A waveform per input, like the music one in the iPhone's Dynamic Island: its last few levels as
/// rounded bars, newest on the right, that shrink to dots in silence. An input that stays silent
/// turns orange. With two inputs, the microphone is on the left.
private struct LevelsWing: View {
    let coordinator: RecordingCoordinator
    let side: NotchIsland.Side

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
        .wingAlignment(side)
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
