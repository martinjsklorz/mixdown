# Speech models

Mixdown turns speech into text with a model that runs on your Mac. Choose one under
**Settings → Transcription**, in one of two kinds:

- **Live** models transcribe while you record, so the note is ready when you stop. The audio isn't
  kept, so an hours-long meeting takes no more memory than a short one.
- **Offline** models transcribe the whole recording once you stop, keeping its audio in memory
  until then. Qwen3 and MOSS are more accurate than the live model, and MOSS can tell speakers
  apart.

| Kind | Model | Size | Good for |
| ---- | ----- | ---- | -------- |
| Live (default) | Nemotron 3.5 ASR Streaming 0.6B | ~540 MB | Long meetings, text as you speak |
| Offline · Low | Qwen3-ASR 0.6B | ~0.9 GB | Fast, everyday notes |
| Offline · High | Qwen3-ASR 1.7B | ~2.3 GB | Better accuracy, on Macs with 24 GB+ memory |
| Offline · Speakers | MOSS Transcribe Diarize 0.9B | ~1 GB | Meetings: labels who is speaking |
| Offline | Apple Speech | Managed by macOS | Light on memory; kept up to date by macOS |

## Downloading

A model is downloaded once, with **Download Model** on Record, in the Recording menu, the menu bar
or Settings. The time left shows next to the menu bar icon. After switching models, download the
new one before recording.

**Cancel Download** in the menu (or **Cancel** in Settings) stops it. Files already fetched are
kept, so the next download picks up where it left off.

If the model is removed while you record, Mixdown downloads it again before transcribing. That
download can't be cancelled, because the recording is waiting on it.

## Deleting

The model menu under **Settings → Transcription** marks downloaded models with a green check. To
free up disk space, select a model and click the trash button next to the menu. You'll need to
download it again before recording with it.

## Apple Speech

Apple Speech is Apple's on-device model, the one Notes and Voice Memos use, listed first on Macs
that support it. macOS downloads it
once per language, keeps it up to date and shares it with other apps, so it has no trash button;
macOS removes it when no app needs it any more. It doesn't detect the language: **Automatic** uses
your Mac's language.

## Language

Pick the language under **Settings → Transcription**: **Automatic**, or one of English, German,
French, Spanish, Italian, Portuguese, Dutch, Polish, Japanese and Chinese. With **Automatic**, the
model detects the language, except Apple Speech, which uses your Mac's language. MOSS always
detects it, so the picker is off for it.

## Speakers

With MOSS, speaker numbers start over every 10 minutes, so "Speaker 1" may be someone else later
in a long recording. When recording a call, MOSS numbers the speakers within each input, e.g. "Me
(Speaker 1)" and "Me (Speaker 2)" for two people at your Mac, and "Others (Speaker 1)" and
"Others (Speaker 2)" for two people on the call.

The other models, Apple Speech included, don't tell speakers apart, so their lines are just
labeled "Me" and "Others".
