import MixdownCore
import MixdownNotes
import SwiftUI

/// A note in the sidebar list: its title, when it was recorded and the start of its text, and
/// the folder it's in, highlighted while it's selected.
struct NoteRow: View {
    let note: NoteDocument
    let dateFormat: Date.FormatStyle
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(note.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let trigger = note.trigger {
                    TriggerIcon(trigger: trigger)
                }
            }
            HStack(spacing: 6) {
                Text(note.createdAt, format: dateFormat)
                Text(note.snippet.isEmpty ? "No additional text" : note.snippet)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.subheadline)
            if let folder = note.folder {
                Label(folder, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The light orange of the app icon's tracks (a darker icon orange in Dark Mode).
        .background(isSelected ? Color("NoteSelection") : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A small mark for how the recording was started. Notes that don't say show none.
private struct TriggerIcon: View {
    let trigger: RecordingTrigger

    var body: some View {
        let (symbol, label) =
            switch trigger {
            case .manual: ("hand.tap", "Started manually")
            case .automatic: ("autostartstop", "Started automatically for a call")
            case .imported: ("square.and.arrow.down", "Imported from an audio file")
            }
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(label)
            .accessibilityLabel(label)
    }
}
