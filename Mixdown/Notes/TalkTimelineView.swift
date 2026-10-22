import Charts
import MixdownCore
import SwiftUI

/// How long each side of a call talked in every minute: the user's bars above the line, the
/// others' below it, under each side's share of the talking. Hover over a minute for its numbers.
struct TalkTimelineView: View {
    /// Each side's bars reach this high for a minute of talking.
    private static let barHeight: CGFloat = 26
    /// A long call's columns narrow to fit; a short call's widen to this at most.
    private static let maxColumnWidth: CGFloat = 28
    /// A call of a minute or two still gets room for its time labels.
    private static let minChartWidth: CGFloat = 200
    /// The gap between columns, as a part of a minute on each side.
    private static let columnInset = 0.12
    /// Shorter bars still show a word or two, in seconds: about 2 pt.
    private static let minimumBarSeconds = TalkTimeline.interval * 2 / Double(barHeight)
    /// Half a point, in seconds, which leaves a hairline between the two sides' bars.
    private static let baselineGap = TalkTimeline.interval * 0.5 / Double(barHeight)

    let timeline: TalkTimeline

    @State private var hoveredTime: Double?

    private let microphoneColor = Color.accentColor
    private let systemAudioColor = Color.secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Talk Time", systemImage: "person.2.wave.2")
                if let minute = hoveredMinute {
                    Text(summary(forMinute: minute))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            legend
                .font(.callout)
            chart
                .frame(maxWidth: chartWidth, alignment: .leading)
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

    /// One column per minute, the user's bar above the line and the others' below it, with the
    /// minutes marked underneath.
    private var chart: some View {
        Chart {
            RuleMark(y: .value("Seconds", 0))
                .foregroundStyle(Color(nsColor: .separatorColor))
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(0..<timeline.minuteCount, id: \.self) { minute in
                bar(minute: minute, seconds: timeline.microphone[minute], below: false, color: microphoneColor)
                bar(minute: minute, seconds: timeline.systemAudio[minute], below: true, color: systemAudioColor)
            }
        }
        .chartXScale(domain: 0...Double(max(timeline.minuteCount, 1)))
        .chartYScale(domain: -TalkTimeline.interval...TalkTimeline.interval)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: tickMinutes.map(Double.init)) { _ in
                AxisGridLine()
                AxisTick(length: 4)
            }
            // Each label starts at its minute, so none sticks out past the first column; the end
            // has none, as it would stick out past the last.
            AxisMarks(values: tickMinutes.filter { $0 < timeline.minuteCount }.map(Double.init)) { value in
                AxisValueLabel(anchor: .topLeading) {
                    if let minute = value.as(Double.self) {
                        Text(Self.minuteText(Int(minute)))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.frame(height: 2 * Self.barHeight)
        }
        .chartXSelection(value: $hoveredTime)
    }

    private func bar(minute: Int, seconds: TimeInterval, below: Bool, color: Color) -> some ChartContent {
        let length = seconds >= 0.5 ? max(min(seconds, TalkTimeline.interval), Self.minimumBarSeconds) : 0
        let sign: Double = below ? -1 : 1
        return RectangleMark(
            xStart: .value("Minute", Double(minute) + Self.columnInset),
            xEnd: .value("Minute", Double(minute + 1) - Self.columnInset),
            yStart: .value("Seconds", sign * Self.baselineGap),
            yEnd: .value("Seconds", sign * (Self.baselineGap + length))
        )
        .cornerRadius(1.5)
        .foregroundStyle(color)
        .opacity(hoveredMinute == nil || hoveredMinute == minute ? 1 : 0.4)
    }

    /// The minute under the pointer, if any.
    private var hoveredMinute: Int? {
        guard let hoveredTime, timeline.minuteCount > 0 else { return nil }
        return min(max(Int(hoveredTime), 0), timeline.minuteCount - 1)
    }

    /// Where the axis marks a minute: every one for a short call, up to every two hours for a very
    /// long one, so about half a dozen labels fit.
    private var tickMinutes: [Int] {
        let count = timeline.minuteCount
        let step = [1, 2, 5, 10, 15, 30, 60, 120].first { count / $0 <= 6 } ?? 120
        return Array(stride(from: 0, through: count, by: step))
    }

    /// Wide enough for a short call's time labels, and narrow enough that its columns don't
    /// stretch across the note.
    private var chartWidth: CGFloat {
        max(Self.minChartWidth, CGFloat(timeline.minuteCount) * Self.maxColumnWidth)
    }

    /// E.g. "12:00–13:00: Me 35 sec, Others 12 sec".
    private func summary(forMinute minute: Int) -> String {
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
