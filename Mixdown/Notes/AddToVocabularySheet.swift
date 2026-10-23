import AppKit
import MixdownCore
import MixdownNotes
import SwiftUI

/// Adds a word to the vocabulary from a note: what the speech model wrote, usually the text
/// selected in the note, and how it should be written. Corrects it in the existing notes too,
/// unless that's turned off.
struct AddToVocabularySheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var soundsLike: String
    @State private var term = ""
    @State private var correctsExistingNotes = true
    @FocusState private var focusedField: Field?

    private enum Field { case soundsLike, term }

    init(soundsLike: String) {
        _soundsLike = State(initialValue: soundsLike)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Heard as", text: $soundsLike, prompt: Text("cooper netties"))
                        .focused($focusedField, equals: .soundsLike)
                    TextField("Write as", text: $term, prompt: Text("Kubernetes"))
                        .focused($focusedField, equals: .term)
                    Toggle("Correct it in existing notes", isOn: $correctsExistingNotes)
                } header: {
                    Text("Add to Vocabulary")
                } footer: {
                    Text(
                        "Recordings from now on are corrected as they're transcribed. Correcting existing "
                            + "notes changes their files in your notes folder."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
        .onAppear { focusedField = trimmed(soundsLike).isEmpty ? .soundsLike : .term }
    }

    private var canAdd: Bool {
        let soundsLike = trimmed(soundsLike)
        let term = trimmed(term)
        return !soundsLike.isEmpty && !term.isEmpty && soundsLike != term
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        guard canAdd else { return }
        let soundsLike = trimmed(soundsLike)
        let term = trimmed(term)
        environment.preferences.vocabulary = environment.preferences.vocabulary.adding(soundsLike, for: term)
        dismiss()
        guard correctsExistingNotes else { return }

        // Only the word just added, so the other words don't change notes without being asked.
        let vocabulary = Vocabulary(entries: [.init(term: term, soundsLike: [soundsLike])])
        Task { [environment] in
            do {
                guard let changes = try await environment.correctNotes(with: vocabulary) else { return }
                await Notifications.post(
                    title: "Notes Corrected",
                    body: "“\(soundsLike)” → “\(term)”. " + VocabularyReport.message(for: changes)
                )
            } catch {
                await Notifications.post(title: "Couldn't Correct Notes", body: error.localizedDescription)
            }
        }
    }
}

/// The text selected in the key window, such as in a note.
@MainActor
enum SelectedText {
    /// Longer selections are likely not a word the speech model got wrong.
    private static let maxLength = 80

    /// What's selected, as a single line, or `nil` if nothing is, or it's long or several lines.
    /// SwiftUI doesn't tell what's selected in a `Text`, so it's copied with the Copy command
    /// and the clipboard put back the way it was.
    static func current() -> String? {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        let changeCount = pasteboard.changeCount
        guard NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil), pasteboard.changeCount != changeCount
        else { return nil }
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        pasteboard.clearContents()
        pasteboard.writeObjects(saved)

        guard let text, !text.isEmpty, text.count <= maxLength, !text.contains(where: \.isNewline) else {
            return nil
        }
        return text
    }
}
