import MixdownCore
import SwiftUI

/// The Dynamic Island's content: the recording time on one side of the notch and, unless turned off,
/// one waveform for all inputs on the other, on black that runs into the notch. Next to the time, a
/// ring shows how the talking is shared while a call's both sides are recorded. If turned on, the
/// latest words scroll by in a line under all three, translated while the live text is.
struct DynamicIslandView: View {
    /// A wing's margin at the island's outer edge.
    fileprivate static let outerPadding: CGFloat = 10
    /// A wing's margin next to the notch.
    fileprivate static let innerPadding: CGFloat = 6
    /// The rounding of the island's bottom corners.
    fileprivate static let cornerRadius: CGFloat = 10
    /// How far the input levels reach out from the notch.
    static let levelsWingWidth = LevelWaveform.width + outerPadding + innerPadding
    /// The height of the live text's line under the notch.
    static let liveTextHeight: CGFloat = 24
    /// Space left between the wings for the live text on a screen without a notch, which would
    /// otherwise be only as wide as the wings.
    static let liveTextGapWidth: CGFloat = 200

    let environment: AppEnvironment
    /// Left empty in the middle, behind the notch. Without one, zero, or room for the live text.
    let notchWidth: CGFloat
    let layout: DynamicIsland.Layout
    let presence: DynamicIsland.Presence
    let openRecorder: () -> Void
    /// Called with how far the time reaches out from the notch, whenever that changes.
    let timeWingWidthChanged: (CGFloat) -> Void

    /// As last measured, to size the live text's line under the wings.
    @State private var timeWingWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                wing(on: .left)
                // Behind the notch, joining the wings. Rounded like the notch where nothing is out
                // next to or under it.
                UnevenRoundedRectangle(
                    bottomLeadingRadius: isCovered(on: .left) ? 0 : Self.cornerRadius,
                    bottomTrailingRadius: isCovered(on: .right) ? 0 : Self.cornerRadius
                )
                .fill(.black)
                .frame(width: notchWidth)
                wing(on: .right)
            }
            .frame(maxHeight: .infinity)
            if layout.showsLiveText {
                let wings = wingWidths
                LiveTextLine(coordinator: environment.coordinator)
                    .opacity(presence.isExpanded ? 1 : 0)
                    .frame(width: wings.left + notchWidth + wings.right, height: Self.liveTextHeight)
                    .background(.black)
                    .clipShape(
                        LiveTextShape(
                            leadingInset: wings.left,
                            trailingInset: wings.right,
                            progress: presence.isExpanded ? 1 : 0
                        )
                    )
            }
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

    /// Whether the notch's bottom corner on `side` has a wing out beside it or the live text under it.
    private func isCovered(on side: DynamicIsland.Side) -> Bool {
        presence.isExpanded && (hasWing(on: side) || layout.showsLiveText)
    }

    /// How far the wings reach out from the notch on either side.
    private var wingWidths: (left: CGFloat, right: CGFloat) {
        let levels = layout.showsLevels ? Self.levelsWingWidth : 0
        return layout.timeSide == .left ? (timeWingWidth, levels) : (levels, timeWingWidth)
    }

    @ViewBuilder
    private func wing(on side: DynamicIsland.Side) -> some View {
        // Square at the bottom with the live text under it.
        let roundsBottom = !layout.showsLiveText
        if side == layout.timeSide {
            ElapsedWing(environment: environment, side: side, showsTalkShare: layout.showsTalkShare)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                    timeWingWidth = width
                    timeWingWidthChanged(width)
                }
                .wingBackground(side, isExpanded: presence.isExpanded, roundsBottom: roundsBottom)
        } else if layout.showsLevels {
            LevelsWing(coordinator: environment.coordinator, side: side)
                .frame(width: Self.levelsWingWidth)
                .wingBackground(side, isExpanded: presence.isExpanded, roundsBottom: roundsBottom)
        }
    }
}

/// A wing's black, `progress` of the way out from the notch, which is on the side opposite `side`.
private struct WingShape: Shape {
    let side: DynamicIsland.Side
    /// Whether the outer bottom corner is rounded, as it isn't with the live text under it.
    let roundsBottom: Bool
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let width = rect.width * min(max(progress, 0), 1)
        let x = side == .left ? rect.maxX - width : rect.minX
        let radius = roundsBottom ? min(DynamicIslandView.cornerRadius, width) : 0
        return UnevenRoundedRectangle(
            bottomLeadingRadius: side == .left ? radius : 0,
            bottomTrailingRadius: side == .right ? radius : 0
        )
        .path(in: CGRect(x: x, y: rect.minY, width: width, height: rect.height))
    }
}

/// The live text's black, `progress` of the way down from the notch and out under the wings, so
/// it grows and shrinks along with them. Collapsed, it's as wide as the notch: the line's width
/// less the wings, `leadingInset` and `trailingInset`.
private struct LiveTextShape: Shape {
    let leadingInset: CGFloat
    let trailingInset: CGFloat
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let progress = min(max(progress, 0), 1)
        let minX = rect.minX + leadingInset * (1 - progress)
        let maxX = rect.maxX - trailingInset * (1 - progress)
        let frame = CGRect(x: minX, y: rect.minY, width: max(maxX - minX, 0), height: rect.height * progress)
        let radius = min(DynamicIslandView.cornerRadius, frame.height, frame.width / 2)
        return UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius).path(in: frame)
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
    fileprivate func wingBackground(_ side: DynamicIsland.Side, isExpanded: Bool, roundsBottom: Bool) -> some View {
        opacity(isExpanded ? 1 : 0)
            .frame(maxHeight: .infinity)
            .background(.black)
            .clipShape(WingShape(side: side, roundsBottom: roundsBottom, progress: isExpanded ? 1 : 0))
    }
}

/// A pulsing red dot and the time recorded so far; a pause sign instead while paused. After them,
/// the talk share ring, if it's shown and both sides are recorded.
private struct ElapsedWing: View {
    let environment: AppEnvironment
    let side: DynamicIsland.Side
    let showsTalkShare: Bool

    var body: some View {
        let elapsed = environment.recordingElapsed ?? 0
        let isPaused = environment.coordinator.isPaused
        let state = isPaused ? "Recording paused" : "Recording"
        HStack(spacing: 5) {
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(state), \(Duration.seconds(elapsed).formatted(.units(width: .wide)))")
            if showsTalkShare {
                // Takes no room while there's no talk share to show.
                TalkShareRing(coordinator: environment.coordinator)
            }
        }
        .fixedSize()
        .wingPadding(side)
        .accessibilityElement(children: .contain)
    }
}

/// How the talking has been shared so far: the user's part as a white arc from the top, clockwise,
/// on the others' grey. A dim ring until anyone talks; nothing unless both sides are recorded.
/// A view of its own, so only the ring is redrawn as the talk time changes.
private struct TalkShareRing: View {
    private static let diameter: CGFloat = 12
    private static let lineWidth: CGFloat = 2.5

    let coordinator: RecordingCoordinator

    var body: some View {
        if let talkTime = coordinator.talkTime {
            ring(talkTime)
                .padding(.leading, 3)
        }
    }

    private func ring(_ talkTime: TalkTime) -> some View {
        let share = talkTime.microphoneShare
        let description = Self.description(of: talkTime, labels: coordinator.sourceLabels)
        return ZStack {
            Circle()
                .stroke(.white.opacity(share == nil ? 0.2 : 0.35), lineWidth: Self.lineWidth)
            Circle()
                .trim(from: 0, to: share ?? 0)
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .animation(.easeOut(duration: 0.4), value: share)
        .help(description ?? "Talk share: nobody has talked yet")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Talk share")
        .accessibilityValue(description ?? "Nobody has talked yet")
    }

    /// E.g. "Me 42 %, Others 58 %".
    private static func description(of talkTime: TalkTime, labels: SourceLabels) -> String? {
        talkTime.percentages.map { percentages in
            "\(labels.label(for: .microphone)) \(percentages.microphone) %, "
                + "\(labels.label(for: .systemAudio)) \(percentages.systemAudio) %"
        }
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

/// The latest words in one line, the newest at the right edge, translated while the live text is.
/// Earlier words slide off to the left as new ones come in, fading out before the edge.
private struct LiveTextLine: View {
    let coordinator: RecordingCoordinator

    /// More than fit in the line; earlier ones would be out of sight.
    private static let wordCount = 40
    /// How far from the left edge words start to fade.
    private static let fadeWidth: CGFloat = 24

    var body: some View {
        let transcript = coordinator.liveTranscript
        let captions = coordinator.liveCaptions
        let words = captions?.recentWords(Self.wordCount, of: transcript) ?? transcript.recentWords(Self.wordCount)

        HStack(spacing: 4) {
            ForEach(words) { word in
                Text(word.text)
                    .fontWeight(word.isSpeaker ? .semibold : .regular)
                    .foregroundStyle(.white.opacity(word.isSpeaker ? 0.5 : 0.9))
                    // Earlier words only leave out of sight, past the left edge.
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .fixedSize()
        // Overflows to the left, keeping the newest word in sight. Without a minimum width, the
        // frame would grow to the words' width and be centered, cutting off the newest words.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        .animation(.easeOut(duration: 0.3), value: transcript.revision)
        .animation(.easeOut(duration: 0.3), value: captions?.revision)
        .clipped()
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.fadeWidth)
                Rectangle()
            }
        }
        .overlay {
            if words.isEmpty {
                Text(coordinator.isPaused ? "Paused" : "Listening…")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, DynamicIslandView.outerPadding)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(captions == nil ? "Live text" : "Live translation")
        .accessibilityValue(words.filter { !$0.isSpeaker }.map(\.text).joined(separator: " "))
    }
}
