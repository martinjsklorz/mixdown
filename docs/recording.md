# Recording

## Start and stop

- Click the red button on **Record**.
- Choose **Recording → Start Recording** (⌘R).
- Choose **Start Recording** from Mixdown's icon in the menu bar.
- From any other app, press ⌃⌥⌘R. Change that shortcut or turn it off under
  **Settings → General → Global Shortcuts**. If recording can't start yet, Mixdown opens to show
  why.

Do the same again to stop. Recording carries on if you close the window.

## Pause

Click the pause button beside Stop, or choose **Recording → Pause Recording** (⇧⌘P), also in the
menu bar. While paused, Mixdown records nothing, and macOS no longer shows the microphone in use.
Resume the same way to carry on in the same note; the paused time is left out of it.

## Mark a moment

To find something again later, press ⌃⌥⌘M in any app while recording, click the bookmark button
beside Stop, or choose **Recording → Mark Moment**, also in the menu bar. A field drops down under
the notch (or the Dynamic Island, while it shows) with the recording's time:

- Type a few words, or none, and press **Return** to add the moment to the note.
- Press **Escape** or click elsewhere to drop it.
- Type nothing for 5 seconds and it closes, dropping it too.

The field takes the keyboard without switching to Mixdown, so the app you were in gets it back
when the field closes. Marking again while it's open starts over at the new time. Change the
shortcut, or clear it to turn it off, under **Settings → General → Global Shortcuts**; Mixdown only
takes those keys while recording.

The note lists the moments under **Moments** at the end of its summary, or in a section of their
own without one. Each has its time, matching the transcript's, your words, and what was being said
then. See [Notes](notes.md#moments).

## Catch up

If you drifted off, press ⌃⌥⌘C in any app while recording, or choose **Recording → Catch Me Up**,
also in the menu bar. The [summary model](summaries.md#models) sums up the last few minutes of the live text (5 unless
you choose otherwise) in a few points, in a card under the notch (or the Dynamic Island, while it
shows), for example:

> **Last 5 minutes**
>
> - Others proposed moving the launch to March.
> - Budget for the campaign was approved at €50,000.
> - You were asked to send the contract by Friday.

The summary is made on your Mac, like the note's, so it's free and nothing leaves the Mac. It
takes a few seconds; longer stretches are summed up in parts first.

- Click the card, or press the shortcut again, to close it.
- Otherwise it closes once you've had time to read it, but not while the pointer is over it.
- It never takes the keyboard, so you can keep typing in the app you're in.

It needs the live speech model, as that's the one with text while you record, and the summary
model (Apple Intelligence turned on, or an open model downloaded); the card says so if either is
missing. When the live text is
[translated](translation.md), the catch-up is in that language too. It doesn't go into the note.

Choose how many minutes it covers (1, 2, 5, 10 or 15) under **Settings → General → Global
Shortcuts → Catch up on the last**, where you can also change the shortcut or clear it to turn it
off. Mixdown only takes those keys while recording.

## Inputs

Pick inputs in the **Recording** menu, in the menu bar, or under **Settings → Recording**.
Choosing a microphone replaces the current one; choosing it again turns it off, as long as System
Audio stays on. At least one input stays on.

**System Default**, the first microphone in the list and the choice until you pick another,
always records from the Mac's current input: connect AirPods and Mixdown switches to them, take
them out and it's back on the built-in microphone. Pick a specific microphone instead to stay on
it.

Inputs can change while recording too: switch microphones or turn System Audio on and off, and the
recording carries on. If a microphone you picked disappears, Mixdown moves to the default one and
returns to yours when it's back. The note keeps one track per input and lists every device it was
recorded from.

To record both sides of a call, see [Recording calls](calls.md).

## While recording

- With the live model (the default), **Record** shows the words as you speak, about half a second
  behind, labeled **Me** and **Others** when you record a call. With an offline model, Mixdown
  transcribes once you stop and shows its progress on Record and in the menu bar.
- **Record** shows a level meter for each input.
- If an input makes no sound for 10 seconds, Mixdown warns on Record and in the menu bar. See
  [Troubleshooting](troubleshooting.md#system-audio-is-silent).
- If no one speaks for 15 minutes, Mixdown asks **Still Recording?** in a notification, on Record
  and in the menu bar, in case a meeting ended and the recording was left running. Click **Stop
  Recording** or **Keep Recording**, or just speak. Time paused doesn't count. Change how long, or
  choose **Never**, under **Settings → Recording → Silence**.
- Short sounds mark recording starting, pausing, resuming and stopping. See
  [Notifications and sounds](notifications-and-sounds.md).
- To use another summary template for this recording only, pick it on Record while recording or
  transcribing, until the summary starts. See [Summaries](summaries.md#templates).

### The Dynamic Island

With **Settings → Design → Show recording in the Dynamic Island** on (the default), the elapsed
time and the input levels appear in an island around the camera notch instead of the time in the
menu bar. Choose which side the time goes on, and whether the levels show, in the same place; the
levels go on the other side from the time. Click the island to open Record. While you record
both a microphone and system audio, a ring next to the time shows how the talking is shared (see
[Recording calls](calls.md#talk-time)).

Without a notch, the island appears at the top center of the screen and the menu bar keeps the
time too, as it does with another display connected. With the setting off, the time shows in the
menu bar.

## Import a recording

Already have a recording, such as a voice memo or a video of a meeting? Click the import button
next to Record, or choose **File → Import Audio…** (⇧⌘I), and pick the file. Mixdown transcribes
it with the speech model, translates and summarizes it like a recording, and saves it as a note
dated when the file was recorded. M4A, MP3, WAV, AIFF, FLAC, MP4, MOV and most other audio and
video files work. The note is named after its summary, or after the file without one. Record shows
the progress; **Cancel Import** stops it without a note. The file itself stays where it is.

## Menu bar and windows

Mixdown's icon in the menu bar can start, pause and stop recording, pick inputs, download the
model and open Settings without the window. It also shows the download's time left, warnings
about silent inputs and a missing notes folder, and errors.

Recording carries on if you close the window. **Open Mixdown** in the menu bar, **Window →
Mixdown** (⌘0) or the Dock icon brings it back. **View → Record** (⌘1) and **View → Notes** (⌘2)
switch what the window shows.
