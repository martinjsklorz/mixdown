import MixdownCore
import SwiftUI

/// A one-line, non-interactive status item.
///
/// Menu-style extras render a snapshot of their content, so a ticking timer wouldn't update
/// while the menu is open. Recording shows its start time instead.
struct RecordingStatusView: View {
    let phase: RecordingCoordinator.Phase
    /// When the recording started. The phase's start moves later with every pause.
    let recordingStartedAt: Date?
    let engineName: String
    let isModelDownloaded: Bool
    let notesFolder: NotesFolderStore.Status
    let timeRemaining: TimeInterval?

    var body: some View {
        switch phase {
        case .idle where notesFolder.directory == nil:
            // Followed by a Choose Notes Folder button.
            Text(NotesFolderWarning.menuTitle(for: notesFolder) ?? "")
        case .idle where !isModelDownloaded:
            // Followed by a Download Model button.
            Text("Download \(engineName) to start recording")
        case .idle:
            Text("Ready · \(engineName)")
        case .preparingModel(let progress):
            Text("Downloading model… \(ProgressText.detail(progress: progress, remaining: timeRemaining))")
        case .startingCapture:
            Text("Starting to record…")
        case .recording(let startedAt):
            Text("Recording since \((recordingStartedAt ?? startedAt).formatted(date: .omitted, time: .shortened))")
        case .paused(let recorded):
            Text("Paused · \(ProgressText.elapsed(Int(recorded))) recorded")
        case .transcribing(let progress):
            Text("Transcribing… \(ProgressText.detail(progress: progress, remaining: timeRemaining))")
        case .identifyingSpeakers:
            Text("Identifying speakers…")
        case .translating:
            Text("Translating…")
        case .summarizing:
            Text("Summarizing…")
        case .failed:
            // Shown with a Dismiss action further down the menu.
            EmptyView()
        }
    }
}
