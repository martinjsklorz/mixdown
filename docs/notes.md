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
- **Share** it.
- **Delete** it (⌘⌫, or Delete in the sidebar), which moves it to the Trash. Mixdown asks first
  (tick **Do not ask again**, or turn it back on under **Settings → General → Ask before deleting a
  note**), then shows a notification with **Restore** to put the note back. With notifications
  off, notes can only be restored from the Trash.

Right-clicking also offers **Open in Default App**. **File → Open Notes Folder** (⇧⌘O) and
**Reveal Last Note in Finder** take you to the files.

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
| `language` | The recording's language; left out when the model doesn't report one |
| `speakers` | The speaker labels used in the transcript |
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
```
