import MixdownCore
import SwiftUI

/// The notch island's content: the recording time on one side of the notch and, unless turned off,
/// one waveform for all inputs on the other, on black that runs into the notch.
struct NotchIslandView: View {
    /// A wing's margin at the island's outer edge.
    fileprivate static let outerPadding: CGFloat = 10
    /// A wing's margin next to the notch.
    fileprivate static let innerPadding: CGFloat = 6
    /// How far the input levels reach out from the notch.
    static let levelsWingWidth = LevelWaveform.width() + outerPadding + innerPadding

    let environment: AppEnvironment
    /// Left empty in the middle, behind the notch. Zero on screens without one.
    let notchWidth: CGFloat
    let layout: NotchIsland.Layout
    let openRecorder: () -> Void
    /// Called with how far the time reaches out from the notch, whenever that changes.
    let timeWingWidthChanged: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 0) {
            wing(on: .left)
            Color.clear
                .frame(width: notchWidth)
            wing(on: .right)
        }
        // Pinned to the time's edge, which the panel's frame is worked out from.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: layout.timeSide == .left ? .leading : .trailing)
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
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: timeWingWidthChanged)
        } else if layout.showsLevels {
            LevelsWing(coordinator: environment.coordinator, side: side)
                .frame(width: Self.levelsWingWidth)
        }
    }
}

extension View {
    /// Pads a wing's content, leaving more room at the island's outer edge on `side` than next to
    /// the notch.
    fileprivate func wingPadding(_ side: NotchIsland.Side) -> some View {
        padding(side == .left ? .leading : .trailing, NotchIslandView.outerPadding)
            .padding(side == .left ? .trailing : .leading, NotchIslandView.innerPadding)
    }
}

/// A pulsing red dot and the time recorded so far.
private struct ElapsedWing: View {
    let environment: AppEnvironment
    let side: NotchIsland.Side

    var body: some View {
        let elapsed = environment.recordingElapsed ?? 0
        HStack(spacing: 5) {
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
        .fixedSize()
        .wingPadding(side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, \(Duration.seconds(elapsed).formatted(.units(width: .wide)))")
    }
}

/// One waveform for all inputs together that turns orange while any input stays silent.
private struct LevelsWing: View {
    let coordinator: RecordingCoordinator
    let side: NotchIsland.Side

    var body: some View {
        let silent = coordinator.silentDevices

        LevelWaveform(coordinator: coordinator, isSilent: !silent.isEmpty, color: .white.opacity(0.75))
            .help(silent.isEmpty ? "Input level" : "No sound from \(silent.map(\.name).formatted(.list(type: .and)))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Input level")
            .wingPadding(side)
    }
}
