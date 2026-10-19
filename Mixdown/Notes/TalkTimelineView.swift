import MixdownCore
import SwiftUI

/// How long each side of a call talked in every minute: the user's bars above the line, the
/// others' below it, under each side's share of the talking. Hover over a minute for its numbers.
struct TalkTimelineView: View {
    /// Each side's bars reach this high for a minute of talking.
    private static let barHeight: CGFloat = 22
    private static let maxBarWidth: CGFloat = 12

    let timeline: TalkTimeline

    private let microphoneColor = Color.accentColor
    private let systemAudioColor = Color.secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Talk Time", systemImage: "person.2.wave.2")
                .font(.caption)
                .foregroundStyle(.secondary)
            legend
                .font(.callout)
            VStack(alignment: .leading, spacing: 4) {
                bars
                HStack {
                    Text(Self.minuteText(0))
                    Spacer()
                    Text(Self.minuteText(timeline.minuteCount))
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(maxWidth: barsWidth)
            }
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var legend: some View {
        let total = timeline.total
        let percentages = total.percentages ?? (0, 0)
        return HStack(spacing: 16) {
            legendItem(
                timeline.microphoneLabel,
                percent: percentages.microphone,
                seconds: total.microphone,
                color: microphoneColor
            )
            legendItem(
                timeline.systemAudioLabel,
                percent: percentages.systemAudio,
                seconds: total.systemAudio,
                color: systemAudioColor
            )
        }
    }

    private func legendItem(_ label: String, percent: Int, seconds: TimeInterval, color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(label) \(percent) %")
            Text(Self.durationText(seconds))
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
    }

    /// One column per minute, the user's bar above the others'. Narrower columns for longer calls,
    /// so a long one still fits.
    private var bars: some View {
        HStack(alignment: .center, spacing: columnSpacing) {
            ForEach(0..<timeline.minuteCount, id: \.self) { minute in
                VStack(spacing: 1) {
                    bar(timeline.microphone[minute], color: microphoneColor)
                        .frame(height: Self.barHeight, alignment: .bottom)
                    bar(timeline.systemAudio[minute], color: systemAudioColor)
                        .frame(height: Self.barHeight, alignment: .top)
                }
                .frame(maxWidth: Self.maxBarWidth)
                .contentShape(Rectangle())
                .help(help(forMinute: minute))
            }
        }
        .frame(maxWidth: barsWidth, alignment: .leading)
        .background {
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
    }

    private func bar(_ seconds: TimeInterval, color: Color) -> some View {
        let height = Self.barHeight * min(max(seconds / TalkTimeline.interval, 0), 1)
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(color)
            // Even a word or two shows.
            .frame(height: seconds >= 0.5 ? max(height, 2) : 0)
    }

    private var columnSpacing: CGFloat { timeline.minuteCount > 60 ? 1 : 2 }

    /// As wide as the columns at their widest, so a short call's bars don't stretch across.
    private var barsWidth: CGFloat {
        let count = CGFloat(timeline.minuteCount)
        return count * Self.maxBarWidth + (count - 1) * columnSpacing
    }

    /// E.g. "12:00–13:00: Me 35 s, Others 12 s".
    private func help(forMinute minute: Int) -> String {
        let range = "\(Self.minuteText(minute))–\(Self.minuteText(minute + 1))"
        let microphone = Self.durationText(timeline.microphone[minute])
        let systemAudio = Self.durationText(timeline.systemAudio[minute])
        return "\(range): \(timeline.microphoneLabel) \(microphone), \(timeline.systemAudioLabel) \(systemAudio)"
    }

    /// E.g. "5:00", or "1:05:00" past the hour.
    private static func minuteText(_ minute: Int) -> String {
        let hours = minute / 60
        let minutes = minute % 60
        return hours > 0 ? "\(hours):\(minutes < 10 ? "0" : "")\(minutes):00" : "\(minutes):00"
    }

    /// E.g. "4 min 5 sec".
    private static func durationText(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }
}
