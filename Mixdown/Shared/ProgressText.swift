import Foundation

/// Wording for model download and transcription progress, shared by the menu bar, the menu,
/// the main window, Settings and the setup assistant, and for the time recorded.
enum ProgressText {
    /// The time recorded: "0:16", "12:05", "1:02:03".
    static func elapsed(_ seconds: Int) -> String {
        let duration = Duration.seconds(seconds)
        return seconds >= 3600
            ? duration.formatted(.time(pattern: .hourMinuteSecond))
            : duration.formatted(.time(pattern: .minuteSecond))
    }

    /// "34% · about 6 min left", or "34% · estimating time left…" until there's an estimate.
    static func detail(progress: Double, remaining: TimeInterval?) -> String {
        "\(percent(progress)) · \(remaining.map(remainingText) ?? "estimating time left…")"
    }

    /// Short text next to the menu bar icon: "6 min" once estimated, "34%" before.
    static func compact(progress: Double, remaining: TimeInterval?) -> String {
        guard let remaining else { return percent(progress) }
        guard remaining >= 60 else { return "<1 min" }
        return minutes(remaining).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// "about 6 min left", "about 1 hr, 5 min left", "less than a minute left".
    private static func remainingText(_ remaining: TimeInterval) -> String {
        guard remaining >= 60 else { return "less than a minute left" }
        let duration = minutes(remaining).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "about \(duration) left"
    }

    /// "34%", for progress from 0 to 1.
    static func percent(_ progress: Double) -> String {
        progress.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Rounded up to whole minutes: "about 1 min" for 61 s would undersell it.
    private static func minutes(_ seconds: TimeInterval) -> Duration {
        .seconds(Int((seconds / 60).rounded(.up)) * 60)
    }
}
