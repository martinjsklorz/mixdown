import MixdownCore
import SwiftUI

/// The Dynamic Island's content: the recording time on one side of the notch and, unless turned off,
/// one waveform for all inputs on the other, on black that runs into the notch.
struct DynamicIslandView: View {
    /// A wing's margin at the island's outer edge.
    fileprivate static let outerPadding: CGFloat = 10
    /// A wing's margin next to the notch.
    fileprivate static let innerPadding: CGFloat = 6
    /// The rounding of the island's bottom corners.
    fileprivate static let cornerRadius: CGFloat = 10
    /// How far the input levels reach out from the notch.
    static let levelsWingWidth = LevelWaveform.width + outerPadding + innerPadding

    let environment: AppEnvironment
    /// Left empty in the middle, behind the notch. Zero on screens without one.
    let notchWidth: CGFloat
    let layout: DynamicIsland.Layout
    let presence: DynamicIsland.Presence
    let openRecorder: () -> Void
    /// Called with how far the time reaches out from the notch, whenever that changes.
    let timeWingWidthChanged: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 0) {
            wing(on: .left)
            // Behind the notch, joining the wings. Rounded like the notch where no wing is out.
            UnevenRoundedRectangle(
                bottomLeadingRadius: hasWing(on: .left) && presence.isExpanded ? 0 : Self.cornerRadius,
                bottomTrailingRadius: hasWing(on: .right) && presence.isExpanded ? 0 : Self.cornerRadius
            )
            .fill(.black)
            .frame(width: notchWidth)
            wing(on: .right)
        }
        // Pinned to the time's edge, which the panel's frame is worked out from.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: layout.timeSide == .left ? .leading : .trailing)
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture { openRecorder() }
        .help("Open Record")
    }

    private func hasWing(on side: DynamicIsland.Side) -> Bool {
        side == layout.timeSide || layout.showsLevels
    }

    @ViewBuilder
    private func wing(on side: DynamicIsland.Side) -> some View {
        if side == layout.timeSide {
            ElapsedWing(environment: environment, side: side)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: timeWingWidthChanged)
                .wingBackground(side, isExpanded: presence.isExpanded)
        } else if layout.showsLevels {
            LevelsWing(coordinator: environment.coordinator, side: side)
                .frame(width: Self.levelsWingWidth)
                .wingBackground(side, isExpanded: presence.isExpanded)
        }
    }
}

/// A wing's black, `progress` of the way out from the notch, which is on the side opposite `side`.
private struct WingShape: Shape {
    let side: DynamicIsland.Side
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let width = rect.width * min(max(progress, 0), 1)
        let x = side == .left ? rect.maxX - width : rect.minX
        let radius = min(DynamicIslandView.cornerRadius, width)
        return UnevenRoundedRectangle(
            bottomLeadingRadius: side == .left ? radius : 0,
            bottomTrailingRadius: side == .right ? radius : 0
        )
        .path(in: CGRect(x: x, y: rect.minY, width: width, height: rect.height))
    }
}

extension View {
    /// Pads a wing's content, leaving more room at the island's outer edge on `side` than next to
    /// the notch.
    fileprivate func wingPadding(_ side: DynamicIsland.Side) -> some View {
        padding(side == .left ? .leading : .trailing, DynamicIslandView.outerPadding)
            .padding(side == .left ? .trailing : .leading, DynamicIslandView.innerPadding)
    }

    /// Puts a wing on black that grows out of the notch while `isExpanded`, revealing the content
    /// as it goes, and shrinks back into it otherwise.
    fileprivate func wingBackground(_ side: DynamicIsland.Side, isExpanded: Bool) -> some View {
        opacity(isExpanded ? 1 : 0)
            .frame(maxHeight: .infinity)
            .background(.black)
            .clipShape(WingShape(side: side, progress: isExpanded ? 1 : 0))
    }
}

/// A pulsing red dot and the time recorded so far; a pause sign instead while paused.
private struct ElapsedWing: View {
    let environment: AppEnvironment
    let side: DynamicIsland.Side

    var body: some View {
        let elapsed = environment.recordingElapsed ?? 0
        let isPaused = environment.coordinator.isPaused
        let state = isPaused ? "Recording paused" : "Recording"
        HStack(spacing: 5) {
            Group {
                if isPaused {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(.white.opacity(0.75))
                } else {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                }
            }
            .font(.system(size: 8))
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
        .accessibilityLabel("\(state), \(Duration.seconds(elapsed).formatted(.units(width: .wide)))")
    }
}

/// One waveform for all inputs together that turns orange while any input stays silent.
private struct LevelsWing: View {
    let coordinator: RecordingCoordinator
    let side: DynamicIsland.Side

    var body: some View {
        let silent = coordinator.silentDevices

        LevelWaveform(coordinator: coordinator, isSilent: !silent.isEmpty, color: .white.opacity(0.75))
            .help(silent.isEmpty ? "Input level" : "No sound from \(silent.map(\.name).formatted(.list(type: .and)))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Input level")
            .wingPadding(side)
    }
}
