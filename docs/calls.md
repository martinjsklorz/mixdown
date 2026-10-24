# Recording calls

Turn on both your microphone and **System Audio** to capture both sides of a call: your voice
through the microphone, everyone else through your Mac's speakers.

Each input is recorded and transcribed on its own, then the lines are merged by time and labeled
**Me** and **Others**. Change the names under **Settings → Transcription → Speaker Names**.

## Talk time

Talk time is off by default; turn it on under **Settings → Recording → Talk Time**. It applies
from the next recording.

Your microphone and the call are separate tracks, so Mixdown knows exactly whose turn it was and
only has to tell talking from silence on each. While recording, a ring next to the time in the
Dynamic Island shows your share of the talking in white and the others' in grey; hover over it for
the numbers. Turn the ring off under **Settings → Design → Show talk share**.

The note ends with a `## Talk Time` section: each side's share, and a table of how long each
talked in every minute. Mixdown shows it as a chart under the note's date and duration. Talking at
the same time counts for both sides.

Talk time is measured by loudness, after the echo is taken out of the microphone. Steady noise,
like a fan, doesn't count, but other sounds can: music the call plays counts as the others
talking, and with echo removal off and no headphones, the others' voices from your speakers count
for you too.

## Echo

Without headphones, your microphone also hears the other people through your speakers. Mixdown
takes that echo out of the microphone while both inputs record, and drops lines it still
recognizes as echo. Turn this off under **Settings → Recording → Echo**; it applies from the next
recording. Headphones still give the cleanest result.

## Call detection

Mixdown notices when a call starts: when a call or voice chat app has been using a microphone for
a few seconds. It knows Zoom, Microsoft Teams, Webex, Slack, FaceTime, Discord, Mumble, TeamSpeak,
WhatsApp, Telegram, Signal, Element, Viber, GoTo Meeting and Jitsi Meet, and the browsers Safari,
Chrome, Edge, Firefox, Arc, Brave, Vivaldi and Opera. A browser counts as soon as any site uses the
microphone.

Two switches under **Settings → Recording → Calls** decide what happens.

### Notify when calls start and end

On by default. A notification asks **Record This Call?** Click it, or its **Record** button
(which shows when you point at it), to start recording with System Audio turned on, plus your
microphone if one is selected. If Mixdown can't record yet, for example because the model isn't
downloaded, the window opens at **Record** to show why.

The notification goes away when the call ends, and none appears while Mixdown is already
recording. When the call ends while Mixdown is recording (and no other call is going on), a
notification asks **Stop Recording?** Click it, or its **Stop Recording** button, to stop and
transcribe.

### Record calls automatically

Off by default. Recording starts by itself when a call starts, with System Audio turned on, and
stops when the call ends. With notifications on, **Recording Call** and **Call Recording Stopped**
say so instead of asking, and if Mixdown can't record yet, it asks **Record This Call?** after
all. With notifications off, the menu bar icon is the only sign.

A recording you started yourself isn't stopped when a call ends; with notifications on, Mixdown
asks **Stop Recording?** instead.

### Turning it off

With both switches off, calls aren't watched. Turning off **Show notifications** under
**Settings → Notifications** turns off the call notifications too, but not automatic recording.

## Titles and templates for calls

A call recorded from the call notification, or automatically, is titled as one with its app, e.g.
"Zoom call about Release timeline", and gets the summary template chosen for **Detected calls**. Recordings started
any other way aren't, even during a call. Calls in a browser, such as Google Meet, are titled
"Call about …", without the browser. The app is saved in the note's `call_app` field too. See
[Summaries](summaries.md).
