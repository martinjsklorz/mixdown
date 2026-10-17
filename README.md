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
   ⌃⌥⌘R. Change that shortcut or turn it off under **Settings → General**.

With the live model (the default), **Record** shows the words as you speak, about half a second
behind and labeled **Me** and **Others** when you record a call. That text is the note.

Soon after you stop, the note appears under **Today** in the sidebar and opens, rendered much like
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
untick **Show notifications** under **Settings → Notifications**; notes can then only be restored from
the Trash.
**File → Open Notes Folder** and **Reveal Last Note in Finder** take you to the files.

Short sounds mark recording starting and stopping, a note being ready, and something going wrong
(recording couldn't start or stopped early, or a note couldn't be finished), so you can tell from
the menu bar without looking. Pick a different macOS sound, or **None**, for each under
**Settings → Notifications → Sounds**, or untick **Play sounds**. They aren't recorded from system
audio, but without headphones your microphone may hear the start sound.

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

**System Default**, the first microphone in the list and the choice until you pick another, always
records from the Mac's current input: connect AirPods and Mixdown switches to them, take them out
and it's back on the built-in microphone. Pick a specific microphone instead to stay on it.

Inputs can change while recording, too: switch microphones or turn System Audio on and off from
the menu, and the recording carries on. If a microphone you picked disappears, Mixdown moves to
the default one and returns to yours when it's back. The note keeps one track per input and lists
every device it was recorded from.

Each input is recorded and transcribed on its own, then the lines are merged by time and labeled
**Me** and **Others**. Change the names under **Settings → Transcription**.

Wear headphones if you can. Without them your microphone also hears the other people, and while
Mixdown drops lines it recognizes as that echo, it can't catch all of it.

Mixdown notices when a call starts: when a call or voice chat app (Zoom, Microsoft Teams, Webex,
Slack, FaceTime, Discord, Mumble, TeamSpeak, WhatsApp, Telegram, Signal, Element, Viber, GoTo
Meeting, Jitsi Meet) or a browser (Safari, Chrome, Edge, Firefox, Arc, Brave, Vivaldi, Opera) has
been using a microphone for a few seconds. A browser counts as soon as any site uses the microphone.
Two switches under **Settings → Recording → Calls** decide what happens:

- **Notify when calls start and end** (on by default): a notification asks **Record This Call?**
  Click it (or its **Record** button, which shows when you point at it) to start recording with
  System Audio turned on, plus your microphone if one is selected. If Mixdown can't record yet, for
  example because the model isn't downloaded, the window opens at **Record** to show why. The
  notification goes away when the call ends, and none appears while Mixdown is already recording.
  When the call ends while Mixdown is recording (and no other call is going on), a notification asks
  **Stop Recording?** Click it, or its **Stop Recording** button, to stop and transcribe.
- **Record calls automatically** (off by default): recording starts by itself when a call starts,
  the same way, and stops when the call ends. With notifications on, **Recording Call** and **Call
  Recording Stopped** say so instead of asking, and if Mixdown can't record yet, it asks with
  **Record This Call?** after all. With notifications off, the menu bar icon is the only sign.

With both off, calls aren't watched. Turning off **Show notifications** under **Settings → Notifications**
turns off the call notifications too, but not automatic recording.

## Speech models

Choose a model under **Settings → Transcription**, in one of two categories:

- **Live** transcribes while you record, so the note is ready when you stop. The audio isn't kept,
  so an hours-long meeting takes no more memory than a short one.
- **Offline** transcribes the whole recording once you stop. The audio is kept in memory until
  then. It's more accurate, and MOSS can tell speakers apart.

A model is downloaded once, from **Download
Model** in the window, the Recording menu or Settings, and the time left shows next to the menu bar icon. After
switching models, download the new one before recording. **Cancel Download** in the menu (or **Cancel** in Settings) stops
it; files already fetched are kept, so the next download picks up where it left off.
To free up disk space, select a model under **Settings → Transcription** and choose **Delete**;
you'll need to download it again before recording with it.

| Category | Model | Size | Good for |
| -------- | ----- | ---- | -------- |
| Live (default) | Nemotron 3.5 ASR Streaming 0.6B | ~540 MB | Long meetings, text as you speak |
| Offline · Low | Qwen3-ASR 0.6B | ~0.9 GB | Fast, everyday notes |
| Offline · High | Qwen3-ASR 1.7B | ~2.3 GB | Better accuracy, on Macs with 24 GB+ memory |
| Offline · Speakers | MOSS Transcribe Diarize 0.9B | ~1 GB | Meetings: labels who is speaking |

With MOSS, speaker numbers start over every 10 minutes, so "Speaker 1" may be someone else
later in a long recording. When recording a call, MOSS numbers the speakers within each input,
e.g. "Me (Speaker 1)" and "Me (Speaker 2)" for two people at your Mac, and "Others (Speaker 1)"
and "Others (Speaker 2)" for two people on the call. The other models don't tell speakers apart,
so their lines are just labeled "Me" and "Others".

The live model also drops the echo of the call from your microphone's lines in the note, but the
text on screen still shows it while you record.

## Summaries

On macOS 26 or later with Apple Intelligence turned on, each note starts with a summary: a short
overview, the key points and any action items, in the language of the recording. Apple
Intelligence writes it on your Mac after the transcript is ready, so the note takes a little
longer to appear. Nothing extra is downloaded, and the transcript doesn't leave your Mac. Long
recordings are summarized in parts, which are then combined.

The summary also names the note after its topic, e.g. "Release timeline". A call recorded from
Mixdown's call notification, or automatically (see **Settings → Recording**), is titled as one in
the language of the recording, e.g. "Call about Release timeline" or "Anruf zu Budgetplanung".
Recordings started any other way aren't, even during a call. Without a summary, a note is titled
with the date and time it was recorded.

Turn summaries off under **Settings → Transcription**, which also says why summaries aren't
available on this Mac if they aren't. Without them, or if summarizing fails, the note is saved
with just the transcript and the date as its title.

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
title: "Release timeline"
created: 2026-10-13T14:02:11+02:00
duration: 754
source: "MacBook Pro Microphone"
source_kind: microphone
engine: "MOSS Transcribe Diarize 0.9B"
speakers: ["Speaker 1", "Speaker 2"]
tags: [mixdown]
---

# Release timeline

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
