import Foundation

/// `mixdown`: reads the notes in Mixdown's notes folder and controls recording, from a terminal,
/// a script or an AI agent (see `skills/mixdown/SKILL.md`). Works whether or not the app is open,
/// except for controlling recording, which goes through `mixdown://` links.
@main
struct MixdownCLI {
    static func main() async {
        do {
            let invocation = try Invocation(arguments: Array(CommandLine.arguments.dropFirst()))
            let output = try await Runner(invocation).run()
            if !output.isEmpty { print(output) }
        } catch let error as UsageError {
            printError("mixdown: \(error.message)\nRun `mixdown --help` to see how to use it.")
            exit(2)
        } catch {
            printError("mixdown: \(error)")
            exit(1)
        }
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

enum Help {
    static let text = """
        mixdown: read Mixdown's notes and control recording.

        Notes:
          mixdown list                  The 20 newest notes: date, length, title and file
                  [--limit N | --all]   … that many, or all of them
                  [--since YYYY-MM-DD]  … from that day on
                  [--until YYYY-MM-DD]  … up to and including that day
          mixdown search WORDS          Notes with all the words, newest first, with the line
                                        that matches. "Quote" words to find them together.
          mixdown show [NOTE]           A note's Markdown file (the newest without NOTE)
                  --summary             … just its summary
                  --section NAME        … just one section, such as "Action Items"
                  --transcript          … just its transcript, as plain text
          mixdown path [NOTE]           A note's file, or the notes folder without NOTE

          NOTE is a note's path in the notes folder (as list shows it, .md optional), its
          full title (the newest with it), or latest.

        Recording (through the Mixdown app):
          mixdown start | stop | toggle Start or stop recording, like ⌃⌥⌘R
          mixdown stop --wait           Stop, wait for the note to be saved, print its file
                  [--timeout SECONDS]   … giving up after this long (600)
          mixdown pause | resume        Pause or resume the recording
          mixdown toggle-pause          Pause, or resume if paused
          mixdown mark [TEXT]           Mark a moment, with TEXT or the field under the notch
          mixdown open [NOTE]           Open the Mixdown window, or a note in it

        Options:
          --json                        Print notes as JSON, for scripts and agents
          --folder PATH                 Use this notes folder instead of Mixdown's
                                        (or set MIXDOWN_NOTES_FOLDER)
          -h, --help                    Show this help
        """
}
