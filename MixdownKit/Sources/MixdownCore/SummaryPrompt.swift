import Foundation

/// What every summarizer tells its model, whatever the backend: the task, what to look out for and
/// which language to write in. How the answer is shaped is up to the backend; see `JSONSummary` for
/// models that answer in plain text.
public enum SummaryPrompt {
    /// Instructions for summarizing one piece of a recording of `kind`, in the shape of `template`.
    /// - Parameter hasMoments: Whether the user marked moments in the recording, which are lines
    ///   of the transcript; see `momentLine(for:)`.
    public static func instructions(
        for kind: ChunkedSummarizer.Step,
        template: SummaryTemplate,
        language: String?,
        hasMoments: Bool = false
    ) -> String {
        let task =
            switch kind {
            case .transcript:
                """
                You summarize recordings such as meetings, calls and voice memos. The user gives you \
                a transcript or part of one. Lines may start with the speaker's name.
                """
            case .combine:
                """
                You summarize recordings such as meetings, calls and voice memos. The user gives you \
                summaries of consecutive parts of one recording, in order. Merge them into a single \
                summary of the whole recording, combining points that repeat and keeping every \
                decision and action item. Drop questions that a later part answers.
                """
            }
        let moments = hasMoments ? momentsRule(for: kind).map { "\n" + $0 } ?? "" : ""
        return """
            \(task)\(moments)\(focus(of: template).map { "\n" + $0 } ?? "")
            Only use what's in the text; don't add anything. Be brief and concrete. \(languageRule(language))
            """
    }

    /// What the lines from `momentLine(for:)` are and what to do with them, for a step of `kind`.
    /// `nil` when combining, as the summaries of the parts don't say which points were marked;
    /// they're asked to cover them, and combining keeps what matters.
    public static func momentsRule(for kind: ChunkedSummarizer.Step) -> String? {
        guard kind == .transcript else { return nil }
        return """
            Lines starting with "[Marked by the user" are moments the user marked as important \
            while recording, right after what they're about was said, sometimes with a note of \
            their own. Make sure the summary covers what was said there, and use their note to \
            tell what mattered. They aren't part of what was said.
            """
    }

    /// `moment` as a line of the transcript handed to the model, with the user's note if any.
    public static func momentLine(for moment: Moment) -> String {
        let note = ChunkedSummarizer.singleLine(moment.text)
        return note.isEmpty ? "[Marked by the user]" : "[Marked by the user: \(note)]"
    }

    /// What kind of recording `template` is for, and what matters in one: its instructions, cut
    /// to `SummaryTemplate.maximumInstructionsLength`. `nil` if it has none.
    public static func focus(of template: SummaryTemplate) -> String? {
        let instructions = template.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else { return nil }
        return String(instructions.prefix(SummaryTemplate.maximumInstructionsLength))
    }

    /// Instructions for catching someone up on one piece of the last few minutes of a recording
    /// still under way; see `Summarizer.catchUp(on:language:)`.
    public static func catchUpInstructions(for kind: ChunkedSummarizer.Step, language: String?) -> String {
        let task =
            switch kind {
            case .transcript:
                """
                Someone in a meeting or call that's still going on lost focus for a few minutes. The \
                user gives you the transcript of those minutes. Lines may start with the speaker's \
                name. Tell them what they missed, so they can follow again: the topics, what was \
                decided, and anything they were asked or that's expected of them.
                """
            case .combine:
                """
                Someone in a meeting or call that's still going on lost focus for a few minutes. The \
                user gives you short notes on consecutive parts of those minutes, in order. Merge \
                them into one short list of what they missed, combining points that repeat.
                """
            }
        return """
            \(task)
            Only use what's in the text; don't add anything. Keep to what matters most, oldest first. \
            Be brief and concrete. \(languageRule(language))
            """
    }

    /// Instructions for naming a recording after its summary, for models that left the title
    /// out of their answer.
    public static func titleInstructions(language: String?) -> String {
        """
        The user gives you the summary of a recording. Answer with only its topic in two to six \
        words, as a title. Not a sentence; no "Meeting about" or similar, and no quotes. \
        \(languageRule(language))
        """
    }

    /// The title in a model's answer to `titleInstructions`: its first line, without quotes,
    /// a "Title:" label or a final period.
    public static func title(from answer: String) -> String {
        var text = Substring(answer)
        if let end = text.range(of: "</think>") { text = text[end.upperBound...] }
        var title = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        title = title.trimmingCharacters(in: .whitespaces)
        if title.lowercased().hasPrefix("title:") { title = String(title.dropFirst(6)) }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”„*#. ").union(.whitespaces))
        return title
    }

    /// The prompt for one piece: transcript lines are labeled as such, summaries of parts already
    /// say what they are.
    public static func prompt(for text: String, kind: ChunkedSummarizer.Step) -> String {
        kind == .transcript ? "Transcript:\n\(text)" : text
    }

    /// Models answer in the language of their input, and the instructions are English. Without a
    /// firm rule, a German recording gets an English overview, and a catch-up asked for in another
    /// language (when the live text is translated) comes in the recording's.
    static func languageRule(_ language: String?) -> String {
        let languageName = language.flatMap { Locale(identifier: "en").localizedString(forIdentifier: $0) }
        return languageName.map { "You MUST write in \($0)." } ?? "You MUST write in the language of the transcript."
    }

    /// Drops a bullet the model sometimes writes itself, since the note adds its own.
    public static func listItem(_ text: String) -> String {
        var item = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for bullet in ["- ", "• ", "* "] where item.hasPrefix(bullet) {
            item = String(item.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
        }
        return item
    }
}

/// Summaries from models without structured output, which are asked for a JSON object and whose
/// answer is read leniently: reasoning, code fences and text around the object are skipped.
public enum JSONSummary {
    /// Most items asked for in each list, as for Apple's model.
    static let maximumItems = 8
    /// Most points of a catch-up.
    static let maximumCatchUpPoints = 4

    /// How to answer, appended to `SummaryPrompt.instructions`. Keys are listed in the order they
    /// should be written, so the overview and the title can draw on what comes before them. Small
    /// models follow an exact shape better than a description, and the language rule last.
    public static func format(for template: SummaryTemplate, language: String?) -> String {
        let keys: [(String, String)] =
            if template.hasFixedSections {
                [
                    ("decisions", "decisions that were made, one short sentence each; empty if there are none"),
                    ("actionItems", "tasks someone agreed to do, naming who if the text says; empty if there are none"),
                    ("openQuestions", "questions that were raised but not answered, one each; empty if there are none"),
                    ("tldr", "one to three sentences on what the recording is about and its outcome"),
                    ("title", titleDescription),
                ]
            } else {
                [
                    ("keyPoints", "the most important points, decisions and conclusions, one short sentence each"),
                    ("actionItems", "tasks someone agreed to do, naming who if the text says; empty if there are none"),
                    ("overview", "two to four sentences on what the recording is about"),
                    ("title", titleDescription),
                ]
            }
        return object(keys: keys, language: language)
    }

    /// How to answer a catch-up, appended to `SummaryPrompt.catchUpInstructions`.
    public static func catchUpFormat(language: String?) -> String {
        object(
            keys: [
                (
                    "points",
                    "what was missed, oldest first, one short sentence each in your own words, naming who said what where it matters; at most \(maximumCatchUpPoints)"
                )
            ],
            language: language
        )
    }

    private static let titleDescription =
        "the topic in two to six words, as a title. Not a sentence; no \"Meeting about\" or similar"

    /// Keys that hold a string rather than a list.
    private static let textKeys: Set<String> = ["overview", "tldr", "title"]

    private static func object(keys: [(String, String)], language: String?) -> String {
        let shape = keys.map { key, _ in
            textKeys.contains(key) ? "\"\(key)\": \"...\"" : "\"\(key)\": [\"...\"]"
        }
        let lines = keys.map { key, description in
            let limit = textKeys.contains(key) || key == "points" ? "" : "; at most \(maximumItems)"
            return "- \"\(key)\": \(description)\(limit)"
        }
        return """
            Answer with only a JSON object of exactly this shape, with every key, and no other text:
            {\(shape.joined(separator: ", "))}
            \(lines.joined(separator: "\n"))
            Sum up in your own words; don't copy lines from the text. \(SummaryPrompt.languageRule(language))
            """
    }

    /// The summary in `response`, or nil if it holds no JSON object.
    public static func summary(from response: String, template: SummaryTemplate) -> NoteSummary? {
        guard let object = jsonObject(in: response) else { return nil }
        if template.hasFixedSections {
            return NoteSummary(
                template: template,
                title: string(object["title"]),
                overview: string(object["tldr"] ?? object["overview"]),
                decisions: list(object["decisions"]),
                actionItems: list(object["actionItems"]),
                openQuestions: list(object["openQuestions"])
            )
        }
        return NoteSummary(
            template: template,
            title: string(object["title"]),
            overview: string(object["overview"] ?? object["tldr"]),
            keyPoints: list(object["keyPoints"]),
            actionItems: list(object["actionItems"])
        )
    }

    /// The catch-up points in `response`, or nil if it holds no JSON object.
    public static func catchUpPoints(from response: String) -> [String]? {
        jsonObject(in: response).map { Array(list($0["points"]).prefix(maximumCatchUpPoints)) }
    }

    /// The outermost JSON object in `response`, after any `<think>` block. Repaired if need be.
    static func jsonObject(in response: String) -> [String: Any]? {
        var text = Substring(response)
        if let end = text.range(of: "</think>") { text = text[end.upperBound...] }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        let json = String(text[start...end])
        return parse(json) ?? parse(repaired(json))
    }

    private static func parse(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// Fixes the slips small models make: a missing comma between a value that ends a line and a
    /// key that starts the next, and a comma before a closing bracket. Strings in JSON can't hold
    /// a line break, so a line break is always between tokens.
    static func repaired(_ json: String) -> String {
        json.replacing(/(["\]}0-9el])([ \t]*\r?\n\s*)(")/) { "\($0.output.1),\($0.output.2)\($0.output.3)" }
            .replacing(/,(\s*[\]}])/) { String($0.output.1) }
    }

    private static func string(_ value: Any?) -> String {
        switch value {
        case let text as String: text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let items as [Any]: items.compactMap { $0 as? String }.joined(separator: " ")
        default: ""
        }
    }

    /// A list of strings, or a single string as one item. Blank items are dropped.
    private static func list(_ value: Any?) -> [String] {
        let items: [String] =
            switch value {
            case let items as [Any]: items.compactMap { $0 as? String }
            case let text as String: [text]
            default: []
            }
        return items.map(SummaryPrompt.listItem).filter { !$0.isEmpty }
    }
}
