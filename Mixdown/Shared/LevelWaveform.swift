import MixdownCore
import SwiftUI

/// One waveform for all inputs of the running recording together, like the music one in the
/// iPhone's Dynamic Island: the loudest input's last few levels as rounded bars, newest on the
/// right, that shrink to dots in silence. Each bar turns from grey to the accent colour as its
/// level rises.
///
/// Shown in the Dynamic Island and in the Record view.
struct LevelWaveform: View {
    private static let barCount = 5

    /// Levels below this keep `color`; from there to `loudLevel` the bars blend into the accent colour.
    private static let quietLevel = 0.5
    private static let loudLevel = 0.9

    let coordinator: RecordingCoordinator
    /// The bars' colour at quiet levels.
    var color: Color = .secondary
    /// Multiplies the bars' size and spacing, 1 being the Dynamic Island's.
    var scale: CGFloat = 1
    @State private var history = Array(repeating: 0.0, count: barCount)

    private var barWidth: CGFloat { Self.barWidth * scale }
    private var barSpacing: CGFloat { Self.barSpacing * scale }
    private var maxBarHeight: CGFloat { Self.maxBarHeight * scale }

    private static let barWidth: CGFloat = 2.5
    private static let barSpacing: CGFloat = 1.5
    /// Leaves a few points above and below in the Dynamic Island, which is as tall as the notch.
    private static let maxBarHeight: CGFloat = 22

    /// How wide the waveform is at a `scale` of 1.
    static var width: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    /// The loudest selected input right now, system audio included.
    private var combinedLevel: Double {
        let levels = coordinator.inputLevels
        return coordinator.selectedDevices.map { levels[$0.id]?.meterValue ?? 0 }.max() ?? 0
    }

    private func barColor(for level: Double) -> Color {
        let loudness = (level - Self.quietLevel) / (Self.loudLevel - Self.quietLevel)
        return color.mix(with: .accentColor, by: min(max(loudness, 0), 1))
    }

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(history.indices, id: \.self) { index in
                Capsule()
                    .fill(barColor(for: history[index]))
                    .frame(width: barWidth, height: max(barWidth, history[index] * maxBarHeight))
            }
        }
        .frame(height: maxBarHeight)
        .animation(.easeOut(duration: 0.1), value: history)
        // Sampled on a clock rather than on each new level, so the bars keep moving (to dots) while
        // the inputs deliver the same level, such as exact silence.
        .task {
            while !Task.isCancelled {
                history.removeFirst()
                history.append(combinedLevel)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
