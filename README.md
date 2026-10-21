<img src="assets/icon.svg" width="64" height="64" alt="">

# Mixdown

Mixdown records your microphone, whatever your Mac is playing (such as a call or a video), or both
at once, turns the speech into text, and saves it as a Markdown note. It lives in your Mac's menu
bar and has a small main window.

Everything happens on your Mac. Your audio never leaves it.

## Features

- **Record anything**: your microphone, system audio, or both. Pause and resume in the same note.
- **Both sides of a call**: lines from your microphone and from the call are labeled **Me** and
  **Others**, with echo filtered out. A ring in the Dynamic Island shows who's doing the talking,
  and the note gets a minute-by-minute talk timeline.
- **Call detection**: notices calls in Zoom, Teams, FaceTime, Slack, browsers and more, and offers
  to record them, or records them automatically.
- **On-device speech models**: a live model that shows the text as you speak, more accurate
  offline models (one tells speakers apart), or Apple Speech.
- **Custom vocabulary**: tell Mixdown how to write names and jargon the speech model gets wrong,
  right from a note, and every note, old and new, gets them right.
- **Summaries**: Apple Intelligence adds an overview, key points and action items, and names the
  note. Templates for 1:1s, standups and client calls.
- **Catch me up**: drifted off? ⌃⌥⌘C sums up the last few minutes of the live text in a card
  under the notch. Apple Intelligence does it on your Mac, so it's free and private, with no API
  key or local model server to set up.
- **Translation**: notes in another language, translated on your Mac by Apple's translation
  models, with the summary and title in that language too. With the live model, the live text is
  translated as it's spoken, so you can follow a call in a language you don't speak.
- **Plain Markdown notes**: saved to a folder you choose, ready for Obsidian or any editor. Browse,
  search, pin and rename them in Mixdown.
- **Chat across notes**: ask "What did we decide about the release?" and Apple Intelligence
  answers on your Mac from your notes, citing the lines it's from; click one to open the note at
  that line and time. Questions like "How many 1:1s did I have in September?" are counted exactly
  by Mixdown, not guessed by the model.
- **Spotlight search**: every line of every note is in Spotlight, so ⌘Space finds the exact
  transcript line or action item without opening Mixdown.
- **Always at hand**: a global shortcut (⌃⌥⌘R), the menu bar, and a Dynamic Island around the
  camera notch while recording.

## Getting started

Open Mixdown and the setup assistant walks you through choosing a notes folder, downloading a
speech model and picking inputs. Then press ⌘R (or ⌃⌥⌘R from any app) to start and stop
recording. The note opens a few seconds later.

**Help → Mixdown Help** (⌘?) explains everything inside the app.

## Documentation

The [docs](docs/README.md) cover every feature in detail: [recording](docs/recording.md),
[calls](docs/calls.md), [speech models](docs/speech-models.md), [summaries](docs/summaries.md),
[translation](docs/translation.md), [notes and their file format](docs/notes.md), [chat](docs/chat.md),
[settings](docs/settings.md), [shortcuts](docs/keyboard-shortcuts.md) and
[troubleshooting](docs/troubleshooting.md).

## Building from source

You need a Mac with Apple Silicon running macOS 26 or later, Xcode, and
[Homebrew](https://brew.sh).

```sh
make bootstrap   # one-time setup
make run         # build and launch
make test        # run the tests
```

See [Development](docs/development.md) for the rest of the commands and how the code is laid out.

## License

MIT. See [LICENSE](LICENSE).
