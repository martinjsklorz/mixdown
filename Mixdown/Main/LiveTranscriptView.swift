import MixdownCore
import SwiftUI

/// The text recognized so far, shown under the record button while recording, with each line's
/// translation under it while the live text is translated. It follows the newest line unless the
/// user scrolls up to read; scrolling back down follows again.
struct LiveTranscriptView: View {
    let coordinator: RecordingCoordinator

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var followsLatest = true
    @State private var isAtBottom = true

    var body: some View {
        let transcript = coordinator.liveTranscript
        let captions = coordinator.liveCaptions

        VStack(spacing: 8) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(transcript.lines.enumerated()), id: \.element.id) { index, line in
                        // The speaker is named where it changes.
                        let showsSpeaker = index == 0 || transcript.lines[index - 1].speaker != line.speaker
                        LiveLineView(
                            line: line,
                            translation: captions?.translation(of: line),
                            showsSpeaker: showsSpeaker
                        )
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
            // A translation can make the newest line taller.
            .onChange(of: captions?.revision) {
                if followsLatest { position.scrollTo(edge: .bottom) }
            }
            .overlay {
                if transcript.isEmpty, coordinator.isRecording {
                    Text(coordinator.isPaused ? "Paused" : "Listening…")
                        .foregroundStyle(.secondary)
                }
            }
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))

            if let problem = captions?.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            Text(footer(translatedInto: captions?.language))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func footer(translatedInto language: String?) -> String {
        guard let language else { return "This text becomes your note when you stop." }
        return "This text becomes your note when you stop. It's translated into "
            + "\(TranslationSettingsView.name(of: language)) as it's spoken."
    }
}

/// A line of the live text, with its translation under it, if it has one.
private struct LiveLineView: View {
    let line: LiveTranscript.Line
    let translation: String?
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
            if let translation {
                Text(translation)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
