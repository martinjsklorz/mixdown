# Troubleshooting

## System audio is silent

macOS records silence rather than giving an error when Mixdown isn't allowed to record system
audio. Turn Mixdown on in System Settings › Privacy & Security › Screen & System Audio Recording ›
System Audio Recording Only. **Open Privacy Settings…** in the menu bar takes you there when
Mixdown warns about a silent input.

## A microphone is silent

Check that Mixdown is on in System Settings › Privacy & Security › Microphone, and that the
microphone isn't muted.

## Recording won't start

Record says what's missing: choose a notes folder, download the speech model, or reconnect the
drive the notes folder is on.

## A note hasn't been saved yet

The notes folder couldn't be reached when the note was finished. Connect the folder's drive, or
choose another folder under **Settings → General**, and Mixdown saves it. Quitting before then
loses the note. See [Notes](notes.md#when-the-folder-cant-be-reached).

## The speech model is downloading again

The model was removed while Mixdown was recording, for example Apple Speech, which macOS removes
when it thinks no app needs it. Mixdown downloads it again before transcribing, and the note
follows once that's done. This download can't be cancelled, because the recording is waiting on
it.

## The other people show up as "Me"

Your microphone heard them through the speakers. Wear headphones. See
[Recording calls](calls.md#echo).

## Mixdown doesn't offer to record calls

Check **Settings → Recording → Calls** and **Settings → Notifications → Show notifications**, and
that notifications are allowed for Mixdown in System Settings › Notifications. None appears while
Mixdown is already recording.

## No summary

Summaries need Apple Intelligence turned on, or an open summary model downloaded under
**Settings → Summary → Model**. That tab says why they aren't available on this Mac if they
aren't. If summarizing fails, the note is saved with
just the transcript.

## No translation

macOS hasn't downloaded the languages for that recording; Mixdown says which ones. Download them
from **Settings → Translation**, or under System Settings → General → Language &
Region → Translation Languages. See [Translation](translation.md).

## Logs

When building from source, `make logs` follows Mixdown's log output. Otherwise, filter Console for
the subsystem `app.mixdown`.
