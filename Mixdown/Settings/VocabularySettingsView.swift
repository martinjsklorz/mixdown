import MixdownCore
import SwiftUI

/// The words to correct in transcripts: how each is written, and what the speech models write
/// instead. Also corrects the notes already written.
struct VocabularySettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    private var preferences: Preferences { environment.preferences }
    @State private var isConfirmingCorrection = false
    /// What correcting the notes did last, or why it failed.
    @State private var correctionResult: String?

    var body: some View {
        let entries = preferences.vocabulary.entries

        Form {
            Section {
                if entries.isEmpty {
                    Text("No words yet.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Heard as")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Write as")
                            .frame(width: 140, alignment: .leading)
                        // Stands in for the remove button, so the titles line up with the fields.
                        Image(systemName: "minus.circle")
                            .hidden()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(entries) { entry in
                        row(for: entry)
                    }
                }
                Button("Add Word", systemImage: "plus") {
                    preferences.vocabulary.entries.append(.init(term: "", soundsLike: []))
                }
            } header: {
                Text("Vocabulary")
            } footer: {
                Caption(
                    "Names and jargon the speech model gets wrong. Wherever a transcript has what's under "
                        + "Heard as, ignoring case, it gets the word under Write as instead. Separate the ways "
                        + "a word is heard with commas. You can also select a word in a note and choose "
                        + "File › Add to Vocabulary…. Recordings from now on are corrected as they're "
                        + "transcribed."
                )
            }

            Section {
                HStack {
                    Button("Correct Existing Notes…") { isConfirmingCorrection = true }
                        .disabled(
                            preferences.vocabulary.isEmpty || environment.notesFolder.directory == nil
                                || environment.isCorrectingNotes
                        )
                    if environment.isCorrectingNotes {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let correctionResult {
                    Text(correctionResult)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Caption("Makes the same corrections in the notes already in your notes folder, changing their files.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Correct all notes with your vocabulary?", isPresented: $isConfirmingCorrection) {
            Button("Correct Notes") { correctNotes() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every note in your notes folder with a word under Heard as is changed. This can't be undone.")
        }
        // Rows added but never filled in.
        .onDisappear {
            preferences.vocabulary.entries.removeAll {
                $0.term.trimmingCharacters(in: .whitespaces).isEmpty
                    && $0.soundsLike.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            }
        }
    }

    private func row(for entry: Vocabulary.Entry) -> some View {
        HStack {
            TextField("Heard as", text: soundsLikeBinding(for: entry.id), prompt: Text("cooper netties, kuber nettis"))
                .labelsHidden()
            TextField("Write as", text: binding(for: entry.id, \.term), prompt: Text("Kubernetes"))
                .labelsHidden()
                .frame(width: 140)
            Button("Remove", systemImage: "minus.circle") {
                preferences.vocabulary.entries.removeAll { $0.id == entry.id }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Remove \(entry.term)")
        }
    }

    private func binding(for id: UUID, _ keyPath: WritableKeyPath<Vocabulary.Entry, String>) -> Binding<String> {
        Binding(
            get: { preferences.vocabulary.entries.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { value in
                guard let index = preferences.vocabulary.entries.firstIndex(where: { $0.id == id }) else { return }
                preferences.vocabulary.entries[index][keyPath: keyPath] = value
            }
        )
    }

    /// The ways a word is heard as one line, separated by ", ". Each item is kept as typed but for
    /// the space after its comma, so the text reads back the way it was typed.
    private func soundsLikeBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { preferences.vocabulary.entries.first { $0.id == id }?.soundsLike.joined(separator: ", ") ?? "" },
            set: { value in
                guard let index = preferences.vocabulary.entries.firstIndex(where: { $0.id == id }) else { return }
                let items = value.components(separatedBy: ",").enumerated().map { index, item in
                    index > 0 && item.hasPrefix(" ") ? String(item.dropFirst()) : item
                }
                preferences.vocabulary.entries[index].soundsLike = items
            }
        )
    }

    private func correctNotes() {
        let vocabulary = preferences.vocabulary
        correctionResult = nil
        Task {
            do {
                guard let changes = try await environment.correctNotes(with: vocabulary) else { return }
                correctionResult = VocabularyReport.message(for: changes)
            } catch {
                correctionResult = "Couldn't correct notes: \(error.localizedDescription)"
            }
        }
    }
}
