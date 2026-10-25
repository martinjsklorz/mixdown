# Speech models

Mixdown turns speech into text with a model that runs on your Mac. Choose one under
**Settings → Transcription**, in one of two kinds:

- **Live** models transcribe while you record, so the note is ready when you stop. The audio isn't
  kept in memory, so an hours-long meeting takes no more memory than a short one.
- **Offline** models transcribe the whole recording once you stop, keeping its audio in memory
  until then. Qwen3, MOSS and Cohere are more accurate than the live model, and MOSS can tell
  speakers apart.

| Kind | Model | Size | Good for |
| ---- | ----- | ---- | -------- |
| Live (default) | Nemotron 3.5 ASR Streaming 0.6B | ~540 MB | Long meetings, text as you speak |
| Offline · Low | Qwen3-ASR 0.6B | ~0.9 GB | Fast, everyday notes |
| Offline · High | Qwen3-ASR 1.7B | ~2.3 GB | Better accuracy, on Macs with 24 GB+ memory |
| Offline · Speakers | MOSS Transcribe Diarize 0.9B | ~1 GB | Meetings: labels who is speaking |
| Offline · Accuracy | Cohere Transcribe 2B | ~2.3 GB | Accurate in 14 languages, on Macs with 24 GB+ memory |
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

## Cohere Transcribe

Cohere Transcribe knows 14 languages: English, German, French, Spanish, Italian, Portuguese,
Dutch, Polish, Greek, Arabic, Japanese, Chinese, Vietnamese and Korean. Like Apple Speech, it
doesn't detect the language, so pick the one you speak under **Language**. **Automatic** uses your
Mac's language, which is also how to get Greek, Arabic, Vietnamese or Korean, or English if
Cohere doesn't know your Mac's language.

## Language

Pick the language under **Settings → Transcription**: **Automatic**, or one of English, German,
French, Spanish, Italian, Portuguese, Dutch, Polish, Japanese and Chinese. With **Automatic**, the
model detects the language, except Apple Speech and Cohere Transcribe, which use your Mac's
language. MOSS always detects it, so the picker is off for it.

## Vocabulary

Names, product names and jargon often come out wrong, like "cooper netties" for Kubernetes. Add
them under **Settings → Vocabulary**: what to write (**Write as**) and what the model writes
instead (**Heard as**), with commas between several ways it's heard. Every transcript is then
corrected before it's translated and summarized, so the summary and title get the right word
too. Matching ignores case and only replaces whole words: "mix down" doesn't change "remix
down". Text that's already right stays as it is, even when it contains what a word is heard as:
with "New York" heard as "york", "New York" doesn't become "New New York".

Qwen3-ASR is also told the words to expect, so it often writes them right in the first place,
including ways of hearing them you haven't listed. Other models only get the corrections.

Mixdown warns you when **Heard as** is a very short or very common word, like "the" or "und":
every one of them in your notes would be replaced, even where it was right.

To add a word from a note, select what the model got wrong and click the book button above the
note, or choose **File → Add to Vocabulary…**. Type how it should be written, and leave **Correct
it in existing notes** on to fix it in every note in your notes folder right away; a
notification says how many changed. **Correct Existing Notes…** under **Settings → Vocabulary**
does the same for every word in the vocabulary.

Correcting a note changes its file in place: its title, the `# Title` heading and the text below
it. Section headings like `## Transcript` and code blocks stay as they are, and so does the file
name; rename the note to change it. This can't be undone.

## Speakers

With MOSS, speaker numbers start over every 10 minutes, so "Speaker 1" may be someone else later
in a long recording. When recording a call, MOSS numbers the speakers within each input, e.g. "Me
(Speaker 1)" and "Me (Speaker 2)" for two people at your Mac, and "Others (Speaker 1)" and
"Others (Speaker 2)" for two people on the call.

The other models, Apple Speech and Cohere included, don't tell speakers apart, so their lines are just
labeled "Me" and "Others".

With **Settings → Transcription → Tell speakers apart** on, the people on the system audio are told
apart by their voices once the recording ends, with any model: "Others (Speaker 1)", "Others
(Speaker 2)" and so on. Someone who says fewer than 10 words in under 5 seconds in the whole
recording isn't counted as a speaker, as that's mostly a cough, a laugh or a word in a different
tone taken for another voice; what they said goes to the speaker before them.
