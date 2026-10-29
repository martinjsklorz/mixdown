---
name: mixdown
description: Read and search the user's Mixdown notes (Markdown transcripts and summaries of meetings, calls and voice memos recorded on their Mac), and start, stop, pause or mark a Mixdown recording. Use when the user asks about a meeting, call, 1:1, standup or anything they recorded, what someone said or decided, their action items or follow-ups, or to record, stop recording or mark a moment.
---

# Mixdown

Mixdown is a Mac menu bar app that records the microphone and/or system audio, transcribes it on
the Mac and saves each recording as a Markdown note in a notes folder the user chose. The `mixdown`
command reads those notes and controls the app.

Check that it's installed with `command -v mixdown`. If it isn't, the notes are still plain
Markdown files: ask the user where their notes folder is and read the files directly (see
[Note format](#note-format)).

## Finding notes

```sh
mixdown list                          # 20 newest: date, length, title, (path in the notes folder)
mixdown list --since 2026-10-20       # from that day on; --until includes its day; --all for every note
mixdown search acme pricing           # notes with all the words, newest first, with the best line
mixdown search '"release date"'       # double quotes find words together
mixdown list --json                   # the same as JSON; search and show take --json too
```

`search` matches every word, ignoring case and accents, in a note's title, text or subfolder. It
finds words, not meaning: try synonyms, names and fewer words if nothing turns up. Dates in `list`
are in the Mac's time zone. To answer "what happened this week", list by date rather than search.

JSON fields per note: `title`, `path` (full), `relative_path`, `created` (ISO 8601), `duration`
(seconds), `sources`, `folder`, `pinned`, `call`, `trigger` (`manual`, `automatic` or `imported`),
`template`, `speakers`, `snippet`, and `match` from `search`.

## Reading a note

A note is named by its path in the notes folder as `list` prints it (`.md` optional), its full
title (the newest with that title), or `latest`. Without one, `show` takes the latest note.

```sh
mixdown show latest --summary                    # the summary: overview, key points, action items, moments
mixdown show "Clients/Acme/2026-10-24 0930 Weekly Sync" --section "Action Items"
mixdown show "Weekly Sync" --transcript          # the transcript as plain text
mixdown show latest                              # the whole Markdown file, frontmatter included
mixdown path latest                              # the file's full path; `mixdown path` alone is the folder
```

Transcripts of long meetings are long. Read the `--summary` first and go to the `--transcript` (or
`search`) only for details, quotes or what the summary leaves out. A note without a summary has no
`## Summary` section; `--section` lists the sections a note has when the one asked for is missing.

When quoting a note, give its title and date, and the transcript time (`[00:12:34]`) for quotes.

## Recording

These send `mixdown://` links to the app. Only use them when the user asks to record, stop or mark.

```sh
mixdown start              # does nothing if already recording; opens Mixdown if it can't start
mixdown stop               # does nothing if not recording
mixdown stop --wait        # stop, then wait for the note (up to 10 min, --timeout SECONDS) and print its path
mixdown pause | resume | toggle | toggle-pause
mixdown mark "Budget approved"   # mark this moment in the recording, with a few words
mixdown open latest        # show a note in the Mixdown window
```

The command can't tell whether Mixdown is recording, and prints nothing when the link was sent.
`stop`, `pause`, `resume` and `mark` fail if Mixdown isn't running. After `stop --wait` prints a
path, read the note with `mixdown show <path> --summary`. Transcribing and summarizing take a while
after stopping, from seconds up to minutes for a long recording.

## Note format

Markdown with YAML frontmatter, saved as `yyyy-MM-dd HHmm Title.md`, possibly in subfolders:

```markdown
---
title: "Release timeline"
created: 2026-10-13T14:02:11+02:00
duration: 754
sources: ["MacBook Pro Microphone", "System Audio"]
speakers: ["Me", "Others"]
call: true
call_app: Zoom
tags: [mixdown]
---

# Release timeline

## Summary

The team went through the release timeline.

### Key Points

- The release moves to Friday.

### Action Items

- [ ] Others update the release notes.

### Moments

- **[00:12:34]** Budget approved — _Others: “so we can go up to fifty thousand…”_

## Transcript

**[00:00:00] Me:** Morning, everyone.

**[00:00:03] Others:** Let's look at the release plan.
```

- **Me** is the user (their microphone); **Others** is everyone on the call (system audio). Notes
  recorded with a speaker-separating model use `Speaker 1`, `Speaker 2`, …, or names the user
  gave them.
- **Moments** are points the user marked while recording, with their own words: treat them as
  important.
- Other sections a note can have: `## Translation` (the transcript in another language, before the
  original), `## Moments` (when there's no summary) and `## Talk Time`.
- Action items are Markdown checkboxes; `- [x]` is done.

## Changing notes

Notes are the user's files, and Mixdown, Obsidian or Spotlight may be watching them. Only change
or delete one when asked. Edit the file in place and keep its frontmatter; Mixdown picks the change
up by itself. Renaming should go through Mixdown (it renames the title and the file together).
