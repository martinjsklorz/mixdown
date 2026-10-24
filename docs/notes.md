# Notes

## The sidebar

Your recordings are listed in the sidebar under **Today**, **Previous 7 Days** and then each
month, rendered much like Apple Notes when you open one. Pinned notes stay at the top under
**Pinned**; click that heading to fold them away or show them again. Search the sidebar (⌘F) to
find older recordings.

A small icon next to a note says how its recording started: a hand for one you started (including
from a call notification), and the autostart icon for a call Mixdown recorded automatically.

## Working with a note

The buttons above a note, right-clicking it in the sidebar, and the File and Edit menus can:

- **Pin** it to keep it at the top of the sidebar, and **Unpin** it again. Pinning sets
  `pinned: true` in the note's frontmatter, so it travels with the file.
- **Rename** it. This changes both the title inside the note and its file name. File names leave
  out characters that break Obsidian links: `[ ]` become `( )`, `|` becomes `-`, and `#` and `^`
  are dropped.
- **Copy Transcript** as plain text. A notification confirms it.
- **Add to Vocabulary** a word the speech model got wrong: select it first, then say how it's
  written. It's corrected in this note and all the others. See
  [Speech models](speech-models.md#vocabulary).
- **Share** it.
- **Delete** it (⌘⌫, or Delete in the sidebar), which moves it to the Trash. Mixdown asks first
  (tick **Do not ask again**, or turn it back on under **Settings → General → Ask before deleting a
  note**), then shows a notification with **Restore** to put the note back. With notifications
  off, notes can only be restored from the Trash.

Right-clicking also offers **Open in Default App**. **File → Open Notes Folder** (⇧⌘O) and
**Reveal Last Note in Finder** take you to the files.

## Searching in Spotlight

Your notes are in Spotlight (⌘Space), so you can find them without opening Mixdown. Every line of
a note is a result of its own, like a transcript line or an action item, so searching for "release
timeline" shows the line that mentions it, with the note's title and the time it was said. Click a
result to open the note in Mixdown, scrolled to that line.

To ask questions across your notes instead, use [Chat](chat.md).

Notes you edit, rename or delete in another app are updated in Spotlight too, even while Mixdown's
window is closed. Turn it off under **Settings → General → Show notes in Spotlight**, which takes
the notes out of Spotlight again. The index stays on your Mac.

## The notes folder

Each note is a Markdown file in a folder you choose the first time you open Mixdown, for example a
new `Mixdown` folder in Documents (use **New Folder** in the dialog). Change it under
**Settings → General**. Notes work with any Markdown editor, such as Obsidian.

Notes you file into subfolders of the notes folder are listed too, with their folder under the
title. Hidden folders, like Obsidian's `.obsidian` and `.trash`, are skipped.

Notes recorded by earlier versions of Mixdown, which saved them inside the app's container at
`~/Library/Containers/app.mixdown.Mixdown/Data/Documents/Mixdown`, move to the folder you choose.

### When the folder can't be reached

If the folder can't be reached, for example because it's on a drive that isn't connected, Mixdown
says so on **Record**, in the menu bar and in Settings, and doesn't record until it's back or you
choose another folder. It picks the folder up again as soon as the drive is connected.

A note finished while the folder was away is kept in memory until it can be saved: Mixdown tries
again every 30 seconds and as soon as you choose another folder. Keep Mixdown open until then; if
you quit first, it warns that the note would be lost.

## The file format

A note is Markdown with YAML frontmatter:

```markdown
---
title: "Release timeline"
created: 2026-10-13T14:02:11+02:00
duration: 754
source: "MacBook Pro Microphone"
source_kind: microphone
engine: "MOSS Transcribe Diarize 0.9B"
trigger: manual
language: "en"
speakers: ["Speaker 1", "Speaker 2"]
tags: [mixdown]
---

# Release timeline

## Summary

The team went through the release timeline for the weekly sync.

### Key Points

- The release moves to Friday.

### Action Items

- [ ] Speaker 2 updates the release notes.

## Transcript

**[00:00:00] Speaker 1:** Okay, let's get started with the weekly sync.

**[00:00:04] Speaker 2:** First up, the release timeline…
```

| Field | Meaning |
| ----- | ------- |
| `title` | The note's title, also its file name |
| `created` | When the recording started |
| `duration` | Length in seconds, without paused time |
| `source` / `sources` | The device, or devices, recorded from |
| `source_kind` / `source_kinds` | `microphone` or `systemAudio` for each source |
| `engine` | The speech model that transcribed it |
| `trigger` | `manual` for recordings you started (including from a call notification), `automatic` for calls recorded automatically |
| `call` | `true` for recordings started from the call notification or automatically |
| `call_app` | For those calls: the app the call was in, e.g. `Zoom`, or the browser for a call in a website |
| `template` | The [summary template](summaries.md#templates) when it isn't General: `oneOnOne`, `standup` or `clientCall`. [Chat](chat.md#counting) counts notes by it |
| `language` | The recording's language; left out when the model doesn't report one |
| `speakers` | The speaker labels used in the transcript |
| `translation_language` | The language of the `## Translation` section, when the note was translated (see [Translation](translation.md)) |
| `talk_labels`, `talk_microphone`, `talk_system_audio` | For calls: the two sides' names, then the seconds each talked in every minute (see [Recording calls](calls.md#talk-time)) |
| `pinned` | `true` when the note is pinned |
| `tags` | Always includes `mixdown` |

A call recorded from a microphone and system audio lists both sources and labels each line:

```markdown
sources: ["MacBook Pro Microphone", "System Audio"]
source_kinds: [microphone, systemAudio]
speakers: ["Me", "Others"]
…
**[00:00:00] Me:** Morning, everyone.

**[00:00:03] Others:** Let's look at the release plan.
…

## Talk Time

**Me** 38 % (4 min 46 s) · **Others** 62 % (7 min 50 s)

| Minute | Me | Others |
| --- | --- | --- |
| 00:00:00 | ███ 18 s | ██████ 37 s |
…
```

### Moments

Moments you marked while recording (see [Recording](recording.md#mark-a-moment)) come last in the
summary, under `### Moments`, or in a `## Moments` section before the transcript when the note has
no summary. Each gives the time, your words, and what was being said then, from the translation
if there is one:

```markdown
### Moments

- **[00:12:34]** Budget approved — _Others: “so we can go up to fifty thousand…”_
- **[00:20:05]** _Me: “I'll send the contract tomorrow.”_
```
