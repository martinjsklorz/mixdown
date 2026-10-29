# Command line and AI agents

The `mixdown` command lists, searches and prints your notes, and starts and stops recording, from
Terminal or a script. An agent skill teaches AI agents like Claude Code and Codex to use it, so you
can ask your agent things like "What are my action items from today's calls?" or "What did Anna
say about pricing last week?", or tell it to record.

Reading notes works whether or not Mixdown is open. Everything stays on your Mac, unless the agent
you use sends what it reads to its model, as cloud-based agents do.

## Installing

The command and the skill come with the source, not the app (see
[Building from source](development.md#building-from-source)):

```sh
make install-cli     # builds `mixdown` and puts it in /usr/local/bin (asks for your password)
make install-skill   # puts the skill in ~/.claude/skills/mixdown, for Claude Code
```

For another agent, give its skills folder, for example `make install-skill SKILL_DIR=~/.codex/skills`
for Codex. The skill is `skills/mixdown/SKILL.md`, so you can also copy it by hand.

## The notes folder

`mixdown` reads the notes folder you chose in Mixdown. The first time, macOS may ask whether
Terminal (or the app running the agent) may access data from other apps: that's Mixdown's settings,
where the folder is stored. To use another folder, or if you said no, pass `--folder PATH` or set
`MIXDOWN_NOTES_FOLDER`:

```sh
export MIXDOWN_NOTES_FOLDER=~/Documents/Mixdown
```

`mixdown path` prints the folder it uses.

## Finding and reading notes

| Command | What it does |
| ------- | ------------ |
| `mixdown list` | The 20 newest notes: date, length, title and file. `--limit N` or `--all` for more |
| `mixdown list --since 2026-10-20 --until 2026-10-24` | The notes recorded on those days |
| `mixdown search acme pricing` | Notes with all the words, newest first, each with the line that matches best. Works like [search in the sidebar](notes.md#the-sidebar), `"quotes"` included |
| `mixdown show` | The newest note's Markdown file, frontmatter included |
| `mixdown show "Weekly Sync" --summary` | Just the summary of the newest note titled Weekly Sync |
| `mixdown show latest --section "Action Items"` | Just one section, up to the next heading of its level |
| `mixdown show latest --transcript` | The transcript as plain text |
| `mixdown path latest` | The note's file |

A note is named by its path in the notes folder, as `list` shows it (`.md` optional), by its full
title (the newest note with it), or by `latest`, like in [`mixdown://open` links](keyboard-shortcuts.md#links-for-other-apps).

Add `--json` to `list`, `search` and `show` for JSON, with the fields of the
[file format](notes.md#the-file-format) and each note's `path` and `relative_path`. `show --json`
also has the note's `body` and its `transcript` as plain text.

## Recording

These send [`mixdown://` links](keyboard-shortcuts.md#links-for-other-apps) to Mixdown, in the
background, so the app you're in stays at the front:

| Command | What it does |
| ------- | ------------ |
| `mixdown start`, `mixdown stop`, `mixdown toggle` | Start or stop recording, like ⌃⌥⌘R. Starting opens Mixdown if it isn't running |
| `mixdown stop --wait` | Stop, wait until the note is saved, and print its file. Gives up after 10 minutes, or `--timeout SECONDS` |
| `mixdown pause`, `mixdown resume`, `mixdown toggle-pause` | Pause or resume the recording |
| `mixdown mark "Budget approved"` | Mark a moment with these words; `mixdown mark` alone opens the field under the notch |
| `mixdown open`, `mixdown open latest` | Bring the Mixdown window forward, or open a note in it |

Mixdown doesn't tell the command whether it's recording, so starting while recording or stopping
while not does nothing, and `stop --wait` waits in vain. Stopping, pausing, resuming and marking
fail when Mixdown isn't running, rather than opening it.

## The agent skill

The skill tells an agent what Mixdown is, how to find, read and quote notes with `mixdown`, what's
in a note (who **Me** and **Others** are, what Moments are), and to record or change notes only
when you ask. Agents load it by themselves when you ask about a meeting, call or recording.
