import AppKit
import SwiftUI

/// The setup assistant's first page: what Mixdown does.
struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.top, 36)
            Text("Welcome to Mixdown")
                .font(.largeTitle.weight(.semibold))
                .padding(.top, 12)
            Text("A few steps, and you're ready to record.")
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 18) {
                feature(
                    "waveform.and.mic",
                    "Record anything",
                    "Your microphone, whatever your Mac plays, such as a call, or both at once."
                )
                feature(
                    "doc.text",
                    "Get a Markdown note",
                    "A transcript with a summary on top, saved in a folder you choose."
                )
                feature(
                    "lock.shield",
                    "Stay on your Mac",
                    "Transcribing and summarizing happen here. Your audio never leaves this Mac."
                )
            }
            .padding(.horizontal, 64)
            .padding(.top, 32)
        }
    }

    private func feature(_ systemImage: String, _ title: String, _ detail: String) -> some View {
        GridRow {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
