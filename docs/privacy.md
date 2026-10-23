# Privacy and permissions

Mixdown records, transcribes and summarizes on your Mac. Your audio and transcripts never leave
it. Only the speech models, and an open summary model if you pick one, are downloaded; Apple
Speech, Apple Intelligence and the translation languages are handled by macOS.

Only the note is saved, to the folder you chose. Until then, where the audio is kept depends on
**Settings → Recording → Keep audio until the note is saved**:

- **On Disk** (the default): while you record, the audio is also written to Mixdown's container
  (`~/Library/Containers/app.mixdown.Mixdown/Data/Library/Application Support/Mixdown/Recordings`),
  so quitting, a crash or a failed transcription doesn't lose it. It's deleted as soon as the note
  is saved. A recording whose note wasn't made stays there, under **Unfinished Recordings** on
  Record, until you transcribe or delete it.
- **In Memory Only**: no audio is written to disk. With an offline model it's kept in memory until
  the note is made; with a live model it isn't kept at all. If transcribing fails, an offline
  model's recording stays under **Unfinished Recordings** until Mixdown quits. Quitting while
  recording, or a crash, loses the recording.

Recordings already on disk stay there when you switch to **In Memory Only**, until you transcribe
or delete them.

Notes are also added to Spotlight's index on your Mac, so you can search them there. Turn that off
under **Settings → General → Show notes in Spotlight**.

[Chat](chat.md) answers with Apple Intelligence on your Mac. The passages of your notes it reads,
and their embeddings, are kept in Mixdown's container
(`~/Library/Containers/app.mixdown.Mixdown/Data/Library/Application Support/ChatIndex.plist`), so
only changed notes are read again.

## Permissions

The first time, macOS asks for permission:

- **Microphone**, to record your voice.
- **System Audio Recording**, to record what your Mac plays.
- **Notifications**, for notes being ready and calls. Optional.

Change them in System Settings › Privacy & Security. System audio is under Screen & System Audio
Recording › System Audio Recording Only. macOS gives a muted recording rather than an error when
it's off, which is what Mixdown's 10-second silence warning catches.
