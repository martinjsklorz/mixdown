<img src="assets/icon.svg" width="64" height="64" alt="">

# Mixdown

Mixdown records your microphone, whatever your Mac is playing (such as a call or a video), or
both at once, turns the speech into text, and saves it as a Markdown note. It has a small main
window and also lives in your Mac's menu bar.
Everything happens on your Mac. Your audio never leaves it.

## Using Mixdown

Mixdown's window has a sidebar with **Record** at the top and your recordings below it, in
collapsible sections by day. The cog above the sidebar, next to the sidebar button, opens Settings.

1. Open Mixdown. **Record** shows the big record button and what the next recording uses:
   microphone, system audio, speech model, language and notes folder.
2. The first time, click **Choose Folder…** and pick where your notes go (see [Notes](#notes)),
   then click **Download Model** and wait for it to finish (see [Speech models](#speech-models)).
   Recording stays off until both are done.
3. Pick your inputs in the **Recording** menu (a microphone, **System Audio**, or both), or with
   **Change…** next to the setup summary.
4. Click the red button (or press ⌘R) to record, and again to stop. From any other app, press
   ⌃⌥⌘R. Change that shortcut or turn it off under **Settings → Recording**.

A few seconds later the note appears under **Today** in the sidebar and opens, rendered much like
Apple Notes. A **Note Ready** notification says so too, with **Open** to show the note in Mixdown
and **Show in Finder** for its file, so you can stop from the menu bar and carry on elsewhere.
Click a day to fold it away, and search the sidebar to find older recordings.
The buttons above a note, or right-clicking it in the sidebar, rename it, copy its transcript as
plain text, share it, or move it to the Trash (⌘⌫, or Delete in the sidebar). Renaming changes
both the title inside the note and its file name. The File and Edit menus have the same commands
for the note that's open.
Mixdown asks before moving a note to the Trash (tick **Do not ask again**, or turn it back on under
**Settings → General**), then shows a notification with **Restore** to put the note back. Copying
a transcript is confirmed with a notification too. To turn all of Mixdown's notifications off,
untick **Show notifications** under **Settings → General**; notes can then only be restored from
the Trash.
**File → Open Notes Folder** and **Reveal Last Note in Finder** take you to the files.

**View → Record / Notes** (⌘1, ⌘2) switch the window's section, and **Mixdown → Settings…** (⌘,)
opens Settings. The waveform icon in the menu bar can start and stop recording and pick inputs
without the window, and has **Settings…** too. Recording carries on there if
you close the window; **Open Mixdown** in that menu, **Window → Mixdown** (⌘0) or the Dock icon
brings it back.

The first time, macOS asks for permission: **Microphone** to record your voice, or **System
Audio Recording** to record what your Mac plays. If system audio comes out silent, check that
Mixdown is on under System Settings › Privacy & Security › Screen & System Audio Recording ›
System Audio Recording Only. macOS gives a muted recording rather than an error when it's off,
so while recording Mixdown shows a level meter per input and warns (also in the menu bar) when an
input has made no sound for 10 seconds.

## Recording calls

Turn on both your microphone and **System Audio** to capture both sides of a call: your voice
through the microphone, everyone else through your Mac's speakers. Choosing a microphone in the
menu replaces the current one; choosing it again turns it off, as long as System Audio stays on.

Each input is recorded and transcribed on its own, then the lines are merged by time and labeled
**Me** and **Others**. Change the names under **Settings → Recording**.

Wear headphones if you can. Without them your microphone also hears the other people, and while
Mixdown drops lines it recognizes as that echo, it can't catch all of it.

## Speech models

Choose a model under **Settings → Transcription**. It's downloaded once, from **Download
Model** in the window, the Recording menu or Settings, and the time left shows next to the menu bar icon. After
switching models, download the new one before recording. **Cancel Download** in the menu (or **Cancel** in Settings) stops
it; files already fetched are kept, so the next download picks up where it left off.
To free up disk space, select a model under **Settings → Transcription** and choose **Delete**;
you'll need to download it again before recording with it.

| Model | Size | Good for |
| ----- | ---- | -------- |
| Qwen3-ASR 0.6B (default) | ~0.9 GB | Fast, everyday notes |
| Qwen3-ASR 1.7B | ~2.3 GB | Better accuracy, on Macs with 24 GB+ memory |
| MOSS Transcribe Diarize 0.9B | ~1 GB | Meetings: labels who is speaking |

With MOSS, speaker numbers start over every 10 minutes, so "Speaker 1" may be someone else
later in a long recording. When recording a call, MOSS numbers the speakers within each input,
e.g. "Me (Speaker 1)" and "Me (Speaker 2)" for two people at your Mac, and "Others (Speaker 1)"
and "Others (Speaker 2)" for two people on the call. The other models don't tell speakers apart,
so their lines are just labeled "Me" and "Others".

## Summaries

On macOS 26 or later with Apple Intelligence turned on, each note starts with a summary: a short
overview, the key points and any action items, in the language of the recording. Apple
Intelligence writes it on your Mac after the transcript is ready, so the note takes a little
longer to appear. Nothing extra is downloaded, and the transcript doesn't leave your Mac. Long
recordings are summarized in parts, which are then combined.

Turn summaries off under **Settings → Transcription**, which also says why summaries aren't
available on this Mac if they aren't. Without them, or if summarizing fails, the note is saved
with just the transcript.

## Notes

Notes are saved to a folder you choose the first time you open Mixdown, for example a new
`Mixdown` folder in Documents (use **New Folder** in the dialog). Change it under
**Settings → General**. Notes recorded by earlier versions of Mixdown, which saved them inside
the app's container at `~/Library/Containers/app.mixdown.Mixdown/Data/Documents/Mixdown`, move
to the folder you choose.

If the folder can't be reached, for example because it's on a drive that isn't connected,
Mixdown says so on **Record**, in the menu bar and in Settings, and doesn't record until it's back
or you choose another folder. It picks the folder up again as soon as the drive is connected.

A note looks like this:

```markdown
---
title: "Recording Oct 13, 2026 at 2:02 PM"
created: 2026-10-13T14:02:11+02:00
duration: 754
source: "MacBook Pro Microphone"
source_kind: microphone
engine: "MOSS Transcribe Diarize 0.9B (speakers)"
speakers: ["Speaker 1", "Speaker 2"]
tags: [mixdown]
---

# Recording Oct 13, 2026 at 2:02 PM

## Summary

The team went through the release timeline for the weekly sync.

### Key Points

- The release moves to Friday.

### Action Items

- Speaker 2 updates the release notes.

## Transcript

**[00:00:00] Speaker 1:** Okay, let's get started with the weekly sync.

**[00:00:04] Speaker 2:** First up, the release timeline…
```

A call recorded from a microphone and system audio lists both sources and labels each line:

```markdown
sources: ["MacBook Pro Microphone", "System Audio"]
source_kinds: [microphone, systemAudio]
speakers: ["Me", "Others"]
…
**[00:00:00] Me:** Morning, everyone.

**[00:00:03] Others:** Let's look at the release plan.
```

## Building from source

You need a Mac with Apple Silicon running macOS 15 or later, Xcode, and
[Homebrew](https://brew.sh).

```sh
make bootstrap   # one-time setup
make run         # build and launch
make test        # run the tests
make clean       # quit Mixdown, delete all build output and refresh the Dock icon
```

To sign the app with your Apple developer account, set `DEVELOPMENT_TEAM` in `project.yml`.

The speech engine sits behind one interface (`TranscriptionEngine`), and so does the summarizer
(`Summarizer`), so either can be replaced by changing a single line in
`Mixdown/App/AppEnvironment.swift`.

## License

MIT. See [LICENSE](LICENSE).
