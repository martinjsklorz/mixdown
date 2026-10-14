<img src="assets/icon.svg" width="64" height="64" alt="">

# Mixdown

Mixdown lives in your Mac's menu bar. It records your microphone, whatever your Mac is
playing (such as a call or a video), or both at once, turns the speech into text, and saves it as
a Markdown note.
Everything happens on your Mac. Your audio never leaves it.

## Using Mixdown

1. Click the waveform icon in the menu bar.
2. Pick your inputs: a microphone, **System Audio**, or both.
3. Choose **Start Recording**, and **Stop Recording** when you're done.

A few seconds later the note appears in your notes folder. **Show Notes** in the menu lists
your notes by date and previews the one you pick, much like Apple Notes. **Open Notes Folder**
and **Reveal Last Note** take you to the files.

The first time, macOS asks for permission: **Microphone** to record your voice, or **Screen &
System Audio Recording** to record system audio. Mixdown never records your screen.

## Recording calls

Turn on both your microphone and **System Audio** to capture both sides of a call: your voice
through the microphone, everyone else through your Mac's speakers. Choosing a microphone in the
menu replaces the current one; choosing it again turns it off, as long as System Audio stays on.

Each input is recorded and transcribed on its own, then the lines are merged by time and labeled
**Me** and **Others**. Change the names under **Settings → Recording**.

Wear headphones if you can. Without them your microphone also hears the other people, and while
Mixdown drops lines it recognizes as that echo, it can't catch all of it.

## Speech models

Choose a model under **Settings → Transcription**. It's downloaded once, and the time left
shows next to the menu bar icon. **Cancel Download** in the menu (or **Cancel** in Settings) stops
it; files already fetched are kept, so the next download picks up where it left off.

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

## Notes

Notes are saved to `~/Documents/Mixdown` unless you pick another folder under
**Settings → General**. A note looks like this:

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
```

To sign the app with your Apple developer account, set `DEVELOPMENT_TEAM` in `project.yml`.

The speech engine sits behind one interface (`TranscriptionEngine`), so it can be replaced
by changing a single line in `Mixdown/App/AppEnvironment.swift`.

## License

MIT. See [LICENSE](LICENSE).
