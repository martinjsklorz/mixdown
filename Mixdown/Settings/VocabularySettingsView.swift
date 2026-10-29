import AppKit
import MixdownCore
import SwiftUI
import UniformTypeIdentifiers

/// The words to correct in transcripts: how each is written, and what the speech models write
/// instead. Also corrects the notes already written, and imports and exports the words.
struct VocabularySettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    private var preferences: Preferences { environment.preferences }
    /// Words to correct the notes with, while asking whether to.
    @State private var pendingCorrection: PendingCorrection?
    /// What correcting the notes did last, or why it failed.
    @State private var correctionResult: String?
    /// What importing or exporting did last, or why it failed.
    @State private var fileResult: String?

    private struct PendingCorrection {
        let vocabulary: Vocabulary
        /// Whether it's only the words an import added, rather than the whole vocabulary.
        let isImport: Bool

        var title: String {
            isImport ? "Correct existing notes with the imported words?" : "Correct all notes with your vocabulary?"
        }

        var message: String {
            let words = isImport ? "a way of hearing a word that the file added" : "a word under Heard as"
            return "Every note in your notes folder with \(words) is changed. This can't be undone."
        }
    }

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
                        Text("Fuzzy")
                            .frame(width: 90, alignment: .leading)
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
                        + "transcribed.\n\nFuzzy also corrects spellings close to Write as in new recordings, "
                        + "like “sklortz” for Sklorz: Strict only very close ones, Loose a few more. It's meant "
                        + "for unusual names, so it leaves alone short and common words and any your Mac's "
                        + "spell checker knows. What it corrects is added to Heard as. If one is wrong, remove "
                        + "it and turn Fuzzy off."
                )
            }

            Section {
                HStack {
                    Button("Import…", action: importVocabulary)
                    Button("Export…", action: exportVocabulary)
                        .disabled(preferences.vocabulary.terms.isEmpty)
                }
                if let fileResult {
                    Text(fileResult)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Caption(
                    "Export saves your words as a JSON file, to share with your team, move to another Mac "
                        + "or edit in a text editor. Import adds the words from such a file, or from Muesli's "
                        + "custom words, to yours: new words are added, and new ways of hearing a word are "
                        + "joined to it. Nothing is removed."
                )
            }

            Section {
                HStack {
                    Button("Correct Existing Notes…") {
                        pendingCorrection = PendingCorrection(vocabulary: preferences.vocabulary, isImport: false)
                    }
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
        .confirmationDialog(
            pendingCorrection?.title ?? "",
            isPresented: Binding(get: { pendingCorrection != nil }, set: { if !$0 { pendingCorrection = nil } }),
            presenting: pendingCorrection
        ) { correction in
            Button("Correct Notes") { correctNotes(with: correction.vocabulary) }
                .keyboardShortcut(.defaultAction)
            Button(correction.isImport ? "Not Now" : "Cancel", role: .cancel) {}
        } message: { correction in
            Text(correction.message)
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
            Picker("Fuzzy", selection: binding(for: entry.id, \.fuzzy)) {
                Text("Off").tag(Vocabulary.Fuzziness.off)
                Text("Strict").tag(Vocabulary.Fuzziness.strict)
                Text("Loose").tag(Vocabulary.Fuzziness.loose)
            }
            .labelsHidden()
            .frame(width: 90)
            // Stays enabled while on, so it can be turned off after Write as changed.
            .disabled(!entry.canMatchFuzzily && entry.fuzzy == .off)
            .help(fuzzyHelp(for: entry))
            Button("Remove", systemImage: "minus.circle") {
                preferences.vocabulary.entries.removeAll { $0.id == entry.id }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Remove \(entry.term)")
        }
    }

    private func fuzzyHelp(for entry: Vocabulary.Entry) -> String {
        guard entry.canMatchFuzzily else { return "Only for words of five letters or more, without punctuation" }
        return "Also correct spellings close to \(entry.term)"
    }

    private func binding<Value>(for id: UUID, _ keyPath: WritableKeyPath<Vocabulary.Entry, Value>) -> Binding<Value> {
        Binding(
            get: {
                let entry = preferences.vocabulary.entries.first { $0.id == id }
                return (entry ?? Vocabulary.Entry(term: "", soundsLike: []))[keyPath: keyPath]
            },
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

    private func correctNotes(with vocabulary: Vocabulary) {
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

    /// Asks for a vocabulary file and merges its words into the vocabulary, then offers to correct
    /// the notes with the ones that are new.
    private func importVocabulary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a vocabulary exported from Mixdown, or Muesli's custom words."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let merge = preferences.vocabulary.merging(try Vocabulary.fileEntries(from: Data(contentsOf: url)))
            preferences.vocabulary = merge.vocabulary
            fileResult = merge.summary
            if !merge.newWords.isEmpty, environment.notesFolder.directory != nil, !environment.isCorrectingNotes {
                pendingCorrection = PendingCorrection(vocabulary: merge.newWords, isImport: true)
            }
        } catch {
            fileResult = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func exportVocabulary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Mixdown Vocabulary.json"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try preferences.vocabulary.fileContents().write(to: url)
            fileResult = "Exported to \(url.lastPathComponent)."
        } catch {
            fileResult = "Couldn't export: \(error.localizedDescription)"
        }
    }
}
