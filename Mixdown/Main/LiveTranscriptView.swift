import MixdownCore
import SwiftUI

/// The text recognized so far, shown under the record button while recording. It follows the
/// newest line unless the user scrolls up to read; scrolling back down follows again.
struct LiveTranscriptView: View {
    let coordinator: RecordingCoordinator

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var followsLatest = true
    @State private var isAtBottom = true

    var body: some View {
        let transcript = coordinator.liveTranscript

        VStack(spacing: 8) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(transcript.lines.enumerated()), id: \.element.id) { index, line in
                        // The speaker is named where it changes.
                        let showsSpeaker = index == 0 || transcript.lines[index - 1].speaker != line.speaker
                        LiveLineView(line: line, showsSpeaker: showsSpeaker)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 32
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
            // Only the user's scrolling decides whether to follow; the content growing doesn't.
            .onScrollPhaseChange { _, phase in
                if phase == .idle { followsLatest = isAtBottom }
            }
            .onChange(of: transcript.revision) {
                if followsLatest { position.scrollTo(edge: .bottom) }
            }
            .overlay {
                if transcript.isEmpty, coordinator.isRecording {
                    Text("Listening…")
                        .foregroundStyle(.secondary)
                }
            }
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))

            Text("This text becomes your note when you stop.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LiveLineView: View {
    let line: LiveTranscript.Line
    let showsSpeaker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsSpeaker, let speaker = line.speaker {
                Text(speaker)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
