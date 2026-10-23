# Development

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

## Project layout

The app target (`Mixdown/`) is SwiftUI and AppKit glue. Everything that can be tested without a
window lives in the `MixdownKit` package:

| Module | What it does |
| ------ | ------------ |
| `MixdownCore` | Domain types and protocols, plus `RecordingCoordinator`, which runs a recording from start to saved note. It drains each capture with a `CaptureLoop` and hands the finished tracks, like an imported file's, to a `NotePipeline`: live or offline transcription, telling speakers apart, merging tracks, translation, summary, and saving with a `NoteSaver`. No dependencies beyond Foundation. |
| `MixdownAudio` | Core Audio: microphone capture (HAL IO proc) and system audio (process tap), whose IO blocks only copy samples into a lock-free ring that `IOProcCapture` converts from off the IO thread; the device list, and which apps use a microphone (for call detection). |
| `MixdownSpeechSwift` | Nemotron, Qwen3-ASR and MOSS via [speech-swift](https://github.com/soniqo/speech-swift) (MLX). |
| `MixdownAppleSpeech` | Apple's on-device model via `SpeechAnalyzer`. |
| `MixdownFoundationModels` | Summaries and titles, and Chat's answers, via Apple Intelligence. |
| `MixdownNaturalLanguage` | Embeddings of note passages for Chat, with Apple's on-device contextual embedding models. |
| `MixdownAppleTranslation` | Translating transcripts with Apple's on-device models via the Translation framework. |
| `MixdownNotes` | Rendering notes to Markdown, writing them, reading the notes folder back, and what Spotlight gets of each note (`NoteSearchIndex`; the app's `NoteSpotlight` hands it to Core Spotlight). Also Chat's passages and search (`NoteChatIndex`) and the questions Mixdown answers by counting (`NoteQuestion`). |

The speech engines sit behind one protocol (`TranscriptionEngine`), and so do the summarizer
(`Summarizer`), the translator (`Translator`), and Chat's model (`NoteAnswerer`) and embeddings
(`TextEmbedder`). Speech models from any engine are listed in
`Mixdown/App/TranscriptionModel.swift`; `Mixdown/App/AppEnvironment.swift` wires everything together.
Settings views change `Mixdown/App/Preferences.swift` directly, and `AppEnvironment.applyPreferences()`
hands every change on to the coordinator from one place.

## In-app Help

Mixdown Help (⌘?) is written in `Mixdown/Help/HelpTopic.swift` as Markdown, one topic per case,
rendered like a note. Links of the form `mixdown-help:<topic>` open another topic. When a feature
changes, update the matching topic there and the page in `docs/`.
