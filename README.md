<img src="assets/icon.svg" width="64" height="64" alt="">

# Mixdown

Mixdown records your microphone, whatever your Mac is playing (such as a call or a video), or
both at once, turns the speech into text, and saves it as a Markdown note. It has a small main
window and also lives in your Mac's menu bar.

Everything happens on your Mac. Your audio never leaves it.

## Using Mixdown

Mixdown's window has a sidebar with a search field and the **Record** button (●) at the top, and
your recordings below it under **Today**, **Previous 7 Days** and then each month. The cog above
the sidebar, next to the sidebar button, opens Settings.

1. Open Mixdown. **Record** shows the big record button and what the next recording uses:
   microphone, system audio, speech model, language and notes folder.
2. The first time, the setup assistant walks you through choosing where your notes go (see
   [Notes](#notes)), downloading a speech model (see [Speech models](#speech-models)), picking
   inputs, allowing the microphone and notifications, call detection, the global shortcut and
   launching at login. **Help → Setup Assistant…** opens it again. If you skip it, click **Choose
   Folder…** and **Download Model** on Record instead; recording stays off until both are done.
3. Pick your inputs in the **Recording** menu (a microphone, **System Audio**, or both), or with
   **Change…** next to the setup summary.
4. Click the red button (or press ⌘R) to record, and again to stop. From any other app, press
   ⌃⌥⌘R. Change that shortcut or turn it off under **Settings → General**. The smaller button
   beside Stop (or ⇧⌘P) pauses; nothing is recorded until you resume.

### While recording

With the live model (the default), **Record** shows the words as you speak, about half a second
behind and labeled **Me** and **Others** when you record a call. That text is the note.

Record shows a level meter per input and warns (also in the menu bar) when an input has made no
sound for 10 seconds. The elapsed time shows in the menu bar or, with **Settings → Design → Show
recording in the Dynamic Island** on (the default), in an island around the camera notch with the
input levels. Click the island to open Record.

Short sounds mark recording starting and stopping, a note being ready, and something going wrong
(recording couldn't start or stopped early, or a note couldn't be finished), so you can tell
without looking. Pick a different macOS sound, or **None**, for each under **Settings →
Notifications → Sounds**, or untick **Play sounds**. They aren't recorded from system audio, but
without headphones your microphone may hear the start sound.

### Your notes

Soon after you stop, the note appears under **Today** in the sidebar and opens, rendered much like
Apple Notes. A **Note Ready** notification says so too, with **Open** to show the note in Mixdown
and **Show in Finder** for its file, so you can stop from the menu bar and carry on elsewhere.

Search the sidebar (⌘F) to find older recordings. Notes you file into subfolders of the notes
folder are listed too, with their folder under the title; hidden folders like Obsidian's
`.obsidian` and `.trash` are skipped.

The buttons above a note, or right-clicking it in the sidebar, pin it, rename it, copy its
transcript as plain text, share it, or move it to the Trash (⌘⌫, or Delete in the sidebar). The
File and Edit menus have the same commands for the note that's open.

- Pinned notes stay at the top of the sidebar under **Pinned** (click the heading to fold them
  away). Pinning sets `pinned: true` in the note's frontmatter, so it travels with the file.
- Renaming changes both the title inside the note and its file name. File names leave out
  characters that break Obsidian links: `[ ]` become `( )`, `|` becomes `-`, and `#` and `^` are
  dropped.
- Mixdown asks before moving a note to the Trash (tick **Do not ask again**, or turn it back on
  under **Settings → General**), then shows a notification with **Restore** to put the note back.
  Copying a transcript is confirmed with a notification too.

To turn all of Mixdown's notifications off, untick **Show notifications** under **Settings →
Notifications**; notes can then only be restored from the Trash. **File → Open Notes Folder** and
**Reveal Last Note in Finder** take you to the files.

### Menu bar and windows

Mixdown's icon in the menu bar can start, pause and stop recording and pick inputs without the
window, and has **Settings…** too. Recording carries on there if you close the window; **Open
Mixdown** in that menu, **Window → Mixdown** (⌘0) or the Dock icon brings it back.

**Help → Mixdown Help** (⌘?) explains all of this inside the app, and the Help menu's search field
finds its topics as well as menu commands.

| Shortcut | Action |
| -------- | ------ |
| ⌘R | Start or stop recording |
| ⌃⌥⌘R | Start or stop recording from any app |
| ⇧⌘P | Pause or resume recording |
| ⌘1 / ⌘2 | Show Record / Notes |
| ⌘F | Search recordings |
| ⌘0 | Open the Mixdown window |
| ⇧⌘O | Open the notes folder |
| ⌘⌫ | Move the open note to the Trash |
| ⌘, | Open Settings |
| ⌘? | Open Mixdown Help |

### Permissions

The first time, macOS asks for permission: **Microphone** to record your voice, or **System Audio
Recording** to record what your Mac plays. If system audio comes out silent, check that Mixdown is
on under System Settings › Privacy & Security › Screen & System Audio Recording › System Audio
Recording Only. macOS gives a muted recording rather than an error when it's off, which is what
the 10-second silence warning catches.

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
Mixdown drops lines it recognizes as that echo, it can't catch all of it. The live model's text
on screen still shows the echo while you record; only the note leaves it out.

### Call detection

Mixdown notices when a call starts: when a call or voice chat app (Zoom, Microsoft Teams, Webex,
Slack, FaceTime, Discord, Mumble, TeamSpeak, WhatsApp, Telegram, Signal, Element, Viber, GoTo
Meeting, Jitsi Meet) or a browser (Safari, Chrome, Edge, Firefox, Arc, Brave, Vivaldi, Opera) has
been using a microphone for a few seconds. A browser counts as soon as any site uses the
microphone. Two switches under **Settings → Recording → Calls** decide what happens:

- **Notify when calls start and end** (on by default): a notification asks **Record This Call?**
  Click it (or its **Record** button, which shows when you point at it) to start recording with
  System Audio turned on, plus your microphone if one is selected. If Mixdown can't record yet, for
  example because the model isn't downloaded, the window opens at **Record** to show why. The
  notification goes away when the call ends, and none appears while Mixdown is already recording.
  When the call ends while Mixdown is recording (and no other call is going on), a notification
  asks **Stop Recording?** Click it, or its **Stop Recording** button, to stop and transcribe.
- **Record calls automatically** (off by default): recording starts by itself when a call starts,
  the same way, and stops when the call ends. With notifications on, **Recording Call** and **Call
  Recording Stopped** say so instead of asking, and if Mixdown can't record yet, it asks with
  **Record This Call?** after all. With notifications off, the menu bar icon is the only sign. A
  recording you started yourself isn't stopped when a call ends; with notifications on, Mixdown
  asks **Stop Recording?** instead.

With both off, calls aren't watched. Turning off **Show notifications** under **Settings →
Notifications** turns off the call notifications too, but not automatic recording.

## Speech models

Choose a model under **Settings → Transcription**, in one of two categories:

- **Live** transcribes while you record, so the note is ready when you stop. The audio isn't kept,
  so an hours-long meeting takes no more memory than a short one.
- **Offline** transcribes the whole recording once you stop. The audio is kept in memory until
  then. Qwen3 and MOSS are more accurate than the live model, and MOSS can tell speakers apart.

| Category | Model | Size | Good for |
| -------- | ----- | ---- | -------- |
| Live (default) | Nemotron 3.5 ASR Streaming 0.6B | ~540 MB | Long meetings, text as you speak |
| Offline · Low | Qwen3-ASR 0.6B | ~0.9 GB | Fast, everyday notes |
| Offline · High | Qwen3-ASR 1.7B | ~2.3 GB | Better accuracy, on Macs with 24 GB+ memory |
| Offline · Speakers | MOSS Transcribe Diarize 0.9B | ~1 GB | Meetings: labels who is speaking |
| Offline | Apple Speech | Managed by macOS | Light on memory; kept up to date by macOS |

A model is downloaded once, from **Download Model** in the window, the Recording menu or Settings,
and the time left shows next to the menu bar icon. After switching models, download the new one
before recording. **Cancel Download** in the menu (or **Cancel** in Settings) stops it; files
already fetched are kept, so the next download picks up where it left off. The model menu in
Settings marks downloaded models with a green check. To free up disk space, select a model and
click the trash button next to the menu; you'll need to download it again before recording with
it.

Apple Speech is Apple's on-device model, the one Notes and Voice Memos use. macOS downloads it
once per language, keeps it up to date and shares it with other apps, so it has no trash button.
It doesn't detect the language: **Automatic** uses your Mac's language.

With MOSS, speaker numbers start over every 10 minutes, so "Speaker 1" may be someone else later
in a long recording. When recording a call, MOSS numbers the speakers within each input, e.g. "Me
(Speaker 1)" and "Me (Speaker 2)" for two people at your Mac, and "Others (Speaker 1)" and "Others
(Speaker 2)" for two people on the call. The other models don't tell speakers apart, so their
lines are just labeled "Me" and "Others".

## Summaries

With Apple Intelligence turned on, each note starts with a summary: a short overview, the key
points and any action items, in the language of the recording. Apple Intelligence writes it on
your Mac after the transcript is ready, so the note takes a little longer to appear. Nothing extra
is downloaded, and the transcript doesn't leave your Mac. Long recordings are summarized in parts,
which are then combined. Action items are saved as Markdown checkboxes (`- [ ]`), so you can tick
them off in editors like Obsidian.

The summary also names the note after its topic, e.g. "Release timeline". A call recorded from
Mixdown's call notification, or automatically, is titled as one in the language of the recording,
e.g. "Call about Release timeline" or "Anruf zu Budgetplanung". Recordings started any other way
aren't, even during a call.

Turn summaries off under **Settings → Transcription**, which also says why summaries aren't
available on this Mac if they aren't. Without them, or if summarizing fails, the note is saved
with just the transcript and the date and time it was recorded as its title.

### Templates

Under **Settings → Transcription**, pick a summary template for manual recordings and one for
detected calls (recordings started from the call notification or automatically):

- **General** (the default): overview, key points and action items, as above.
- **1:1**, **Standup** and **Client Call**: always the same four sections, `### TL;DR`,
  `### Decisions`, `### Action Items` (as `- [ ]` checkboxes) and `### Open Questions`, so every
  note of a kind reads the same. A section with nothing in it says _None._ Each template tells
  Apple Intelligence what to look out for, e.g. blockers in a standup or promises made to a
  client.

That template is preselected for each recording. To use another one for this recording only, pick
it under **Record** while recording or transcribing, until the summary starts.

## Notes

Notes are saved to a folder you choose the first time you open Mixdown, for example a new
`Mixdown` folder in Documents (use **New Folder** in the dialog). Change it under **Settings →
General**. Notes recorded by earlier versions of Mixdown, which saved them inside the app's
container at `~/Library/Containers/app.mixdown.Mixdown/Data/Documents/Mixdown`, move to the folder
you choose.

If the folder can't be reached, for example because it's on a drive that isn't connected, Mixdown
says so on **Record**, in the menu bar and in Settings, and doesn't record until it's back or you
choose another folder. It picks the folder up again as soon as the drive is connected.

A note looks like this:

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

`trigger` is `manual` for recordings you started (including from a call notification) and
`automatic` for calls recorded automatically. `language` is left out when the model doesn't report
one. A call recorded from a microphone and system audio lists both sources and labels each line:

```markdown
sources: ["MacBook Pro Microphone", "System Audio"]
source_kinds: [microphone, systemAudio]
speakers: ["Me", "Others"]
…
**[00:00:00] Me:** Morning, everyone.

**[00:00:03] Others:** Let's look at the release plan.
```

## Building from source

You need a Mac with Apple Silicon running macOS 26 or later, Xcode, and
[Homebrew](https://brew.sh).

```sh
make bootstrap   # one-time setup: XcodeGen and the Metal Toolchain
make run         # build and launch
make test        # run the MixdownKit tests
make logs        # follow the app's log output
make format      # format with swift-format (`make lint` checks)
make clean       # quit Mixdown, delete all build output and refresh the Dock icon
```

`Mixdown.xcodeproj` is generated from `project.yml` by XcodeGen and isn't checked in; `make`
regenerates it when needed. To sign the app with your Apple developer account, set
`DEVELOPMENT_TEAM` in `project.yml`.

### Project layout

The app target (`Mixdown/`) is SwiftUI and AppKit glue. Everything that can be tested without a
window lives in the `MixdownKit` package:

| Module | What it does |
| ------ | ------------ |
| `MixdownCore` | Domain types and protocols, plus `RecordingCoordinator`, which runs a recording from start to saved note: captures, live or offline transcription, merging tracks, summary, writing. No dependencies beyond Foundation. |
| `MixdownAudio` | Core Audio: microphone capture (HAL IO proc), system audio (process tap), the device list, and which apps use a microphone (for call detection). |
| `MixdownSpeechSwift` | Nemotron, Qwen3-ASR and MOSS via [speech-swift](https://github.com/soniqo/speech-swift) (MLX). |
| `MixdownAppleSpeech` | Apple's on-device model via `SpeechAnalyzer`. |
| `MixdownFoundationModels` | Summaries and titles via Apple Intelligence. |
| `MixdownNotes` | Rendering notes to Markdown, writing them, and reading the notes folder back. |

The speech engines sit behind one protocol (`TranscriptionEngine`), and so does the summarizer
(`Summarizer`). Speech models from any engine are listed in `Mixdown/App/TranscriptionModel.swift`;
`Mixdown/App/AppEnvironment.swift` wires everything together.

## License

MIT. See [LICENSE](LICENSE).
