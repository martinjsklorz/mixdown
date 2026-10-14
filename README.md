<img src="assets/icon.svg" width="64" height="64" alt="">

# Mixdown

Mixdown lives in your Mac's menu bar. It records your microphone or whatever your Mac is
playing, such as a call or a video, turns the speech into text, and saves it as a Markdown note.
Everything happens on your Mac. Your audio never leaves it.

## Using Mixdown

1. Click the waveform icon in the menu bar.
2. Pick an input: a microphone, or **System Audio**.
3. Choose **Start Recording**, and **Stop Recording** when you're done.

A few seconds later the note appears in your notes folder. **Show Notes** in the menu lists
your notes by date and previews the one you pick, much like Apple Notes. **Open Notes Folder**
and **Reveal Last Note** take you to the files.

The first time, macOS asks for permission: **Microphone** to record your voice, or **Screen &
System Audio Recording** to record system audio. Mixdown never records your screen.

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
later in a long recording.

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
