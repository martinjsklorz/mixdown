import MixdownCore
import MixdownNotes
import SwiftUI

/// Chat across the notes: questions and their answers, each answer with the lines of the notes it
/// cites, and a field to ask the next question. A citation, or a line under the answer, opens its
/// note at that line.
struct ChatView: View {
    let chat: NoteChat
    let notes: [NoteDocument]
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    /// Questions shown before the first one is asked.
    private static let suggestions = [
        "What did we decide about the release?",
        "What are my open action items from last week?",
        "How many 1:1s did I have in September?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            if chat.messages.isEmpty {
                welcome
            } else {
                transcript
            }
            status
            inputField
        }
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItem {
                Button("New Chat", systemImage: "square.and.pencil") {
                    chat.clear()
                    isFieldFocused = true
                }
                .help("New Chat")
                .disabled(chat.messages.isEmpty)
            }
        }
        // Reads notes recorded or changed while the chat is shown.
        .task(id: notes) { chat.update(notes: notes) }
        .onAppear { isFieldFocused = true }
    }

    // MARK: Messages

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Chat with Your Notes")
                .font(.title2.bold())
            Text(
                "Ask about anything you've recorded. Answers cite the lines they're from; click one to open the note there."
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 420)
            VStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button(suggestion) { chat.ask(suggestion) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(chat.messages) { message in
                    switch message.role {
                    case .question:
                        ChatQuestionView(text: message.text)
                    case .answer:
                        ChatAnswerView(message: message)
                    }
                }
            }
            // A comfortable line length when the window is wide.
            .frame(maxWidth: 720)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
    }

    // MARK: Status and input

    /// Says the notes are still being read, or that Apple Intelligence can't answer.
    @ViewBuilder
    private var status: some View {
        if let progress = chat.indexProgress {
            HStack(spacing: 8) {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .frame(width: 80)
                Text(
                    "Reading notes for Chat: \(progress.done) of \(progress.total). Answers may miss notes until it's done."
                )
            }
            .statusStyle()
        } else if case .unavailable(let reason) = chat.answerer.availability {
            Label(
                "\(reason) Without Apple Intelligence, Chat counts notes and shows the lines that match best.",
                systemImage: "exclamationmark.triangle"
            )
            .statusStyle()
        }
    }

    private var inputField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about your notes", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($isFieldFocused)
                .onSubmit(send)
                .padding(.vertical, 7)
            if chat.isAnswering {
                Button("Stop", systemImage: "stop.circle.fill") { chat.stopAnswering() }
                    .help("Stop Answering")
                    .sendButtonStyle()
            } else {
                Button("Ask", systemImage: "arrow.up.circle.fill", action: send)
                    .help("Ask (Return)")
                    .sendButtonStyle()
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: 720)
        .padding(.horizontal, 32)
        .padding(.bottom, 16)
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    private func send() {
        guard !chat.isAnswering, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        chat.ask(draft)
        draft = ""
    }
}

extension View {
    fileprivate func statusStyle() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
    }

    fileprivate func sendButtonStyle() -> some View {
        labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.title)
            .foregroundStyle(Color.accentColor)
            .padding(.bottom, 1)
    }
}

/// A question, on the right like a sent message.
private struct ChatQuestionView: View {
    let text: String

    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color("NoteSelection"), in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 80)
    }
}

/// An answer, rendered as Markdown with its citations as links, then the lines it cites.
private struct ChatAnswerView: View {
    let message: NoteChat.Message
    @Environment(MainNavigation.self) private var navigation

    private static let sourceScheme = "mixdown-source"

    var body: some View {
        let numbers = Set(message.sources.map(\.number))
        let blocks = MarkdownBlock.parse(Self.markdown(message.text, citing: numbers))

        VStack(alignment: .leading, spacing: 12) {
            if message.text.isEmpty && message.isWriting {
                ProgressView()
                    .controlSize(.small)
            } else if message.isError {
                Label(message.text, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        MarkdownBlockView(block: block)
                            .padding(
                                .top,
                                index == 0 ? 0 : MarkdownBlockView.spacing(between: blocks[index - 1], and: block)
                            )
                    }
                }
                .textSelection(.enabled)
                .environment(
                    \.openURL,
                    OpenURLAction { url in
                        guard url.scheme == Self.sourceScheme,
                            let number = Int(url.absoluteString.dropFirst(Self.sourceScheme.count + 1)),
                            let source = message.sources.first(where: { $0.number == number })
                        else { return .systemAction }
                        // Links are opened on the main thread.
                        MainActor.assumeIsolated { open(source) }
                        return .handled
                    }
                )
            }
            if let footnote = message.footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let sources = shownSources
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sources) { source in
                        ChatSourceRow(source: source) { open(source) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The cited sources in the order cited, or all of them for a count or a fallback.
    private var shownSources: [NoteChat.Source] {
        guard !message.showsAllSources else { return message.sources }
        let numbers = ChatCitations.numbers(in: message.text, valid: Set(message.sources.map(\.number)))
        return numbers.compactMap { number in message.sources.first { $0.number == number } }
    }

    private func open(_ source: NoteChat.Source) {
        navigation.showNote(at: source.noteURL, line: source.line)
    }

    /// `text` with each citation of `numbers` as a small link, e.g. `[²](mixdown-source:2)`.
    static func markdown(_ text: String, citing numbers: Set<Int>) -> String {
        ChatCitations.pieces(of: text, valid: numbers).map { piece in
            switch piece {
            case .text(let text): text
            case .citation(let number): "[\(superscript(number))](\(sourceScheme):\(number))"
            }
        }
        .joined()
    }

    private static func superscript(_ number: Int) -> String {
        let digits: [Character] = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]
        return String(String(number).compactMap { $0.wholeNumberValue.map { digits[$0] } })
    }
}

/// A line an answer cites, or a note a count counted: its number, the note's title and date, the
/// time it was said and the line itself. Opens the note there.
private struct ChatSourceRow: View {
    let source: NoteChat.Source
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(source.number)")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(source.noteTitle)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(source.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let time = source.time {
                            Label(time, systemImage: "clock")
                                .labelStyle(.titleAndIcon)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if let section = source.section, !source.text.isEmpty {
                            Text(section)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !source.text.isEmpty {
                        Text(source.text.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(source.line == nil ? "Open Note" : "Open Note at This Line")
    }
}
