import MixdownCore
import SwiftUI

/// One waveform for all inputs of the running recording together, like the music one in the
/// iPhone's Dynamic Island: the loudest input's last few levels as rounded bars, newest on the
/// right, that shrink to dots in silence. Orange while `isSilent`.
///
/// Shown in the Dynamic Island and in the Record view.
struct LevelWaveform: View {
    private static let barCount = 5

    let coordinator: RecordingCoordinator
    let isSilent: Bool
    /// The bars' colour while there is sound.
    var color: Color = .secondary
    /// Multiplies the bars' size and spacing, 1 being the Dynamic Island's.
    var scale: CGFloat = 1
    @State private var history = Array(repeating: 0.0, count: barCount)

    private var barWidth: CGFloat { Self.barWidth * scale }
    private var barSpacing: CGFloat { Self.barSpacing * scale }
    private var maxBarHeight: CGFloat { 16 * scale }

    private static let barWidth: CGFloat = 2.5
    private static let barSpacing: CGFloat = 1.5

    /// How wide the waveform is at a `scale` of 1.
    static var width: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    /// The loudest selected input right now, system audio included.
    private var combinedLevel: Double {
        let levels = coordinator.inputLevels
        return coordinator.selectedDevices.map { levels[$0.id]?.meterValue ?? 0 }.max() ?? 0
    }

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(history.indices, id: \.self) { index in
                Capsule()
                    .frame(width: barWidth, height: max(barWidth, history[index] * maxBarHeight))
            }
        }
        .frame(height: maxBarHeight)
        .foregroundStyle(isSilent ? Color.orange : color)
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
