import KeyboardShortcuts
import SwiftUI

/// A round record button in the style of Voice Memos: a red dot that becomes a stop square.
struct RecordButton: View {
    let isRecording: Bool
    let action: @MainActor () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.secondary.opacity(0.4), lineWidth: 4)
                RoundedRectangle(cornerRadius: isRecording ? 6 : 28)
                    .fill(.red)
                    .frame(width: isRecording ? 28 : 56, height: isRecording ? 28 : 56)
            }
            .frame(width: 72, height: 72)
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: isRecording)
        .accessibilityLabel(isRecording ? "Stop Recording" : "Start Recording")
        .help(isRecording ? "Stop Recording" : "Start Recording")
    }
}

/// A smaller round button beside Stop: a pause sign while recording, and a red dot to record
/// again while paused.
struct PauseButton: View {
    static let size: CGFloat = 44

    let isPaused: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.secondary.opacity(0.4), lineWidth: 3)
                if isPaused {
                    Circle()
                        .fill(.red)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.size, height: Self.size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPaused ? "Resume Recording" : "Pause Recording")
        .help(isPaused ? "Resume Recording (⇧⌘P)" : "Pause Recording (⇧⌘P)")
    }
}

/// A round button on the other side of Stop from Pause, to mark a moment. Shows how many are
/// marked so far.
struct MomentButton: View {
    let momentCount: Int
    let action: @MainActor () -> Void

    var body: some View {
        let shortcut = KeyboardShortcuts.getShortcut(for: .markMoment).map { " (\($0.description))" } ?? ""

        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.secondary.opacity(0.4), lineWidth: 3)
                Image(systemName: momentCount > 0 ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: PauseButton.size, height: PauseButton.size)
            .contentShape(Circle())
            .overlay(alignment: .topTrailing) {
                if momentCount > 0 {
                    Text(momentCount, format: .number)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(.orange, in: Capsule())
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mark Moment")
        .accessibilityValue(momentCount == 1 ? "1 moment marked" : "\(momentCount) moments marked")
        .help("Mark Moment\(shortcut)")
    }
}
