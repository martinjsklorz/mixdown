# Recording calls

Turn on both your microphone and **System Audio** to capture both sides of a call: your voice
through the microphone, everyone else through your Mac's speakers.

Each input is recorded and transcribed on its own, then the lines are merged by time and labeled
**Me** and **Others**. Change the names under **Settings → Transcription → Speaker Names**.

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

A call recorded from the call notification, or automatically, is titled as one, e.g. "Call about
Release timeline", and gets the summary template chosen for **Detected calls**. Recordings started
any other way aren't, even during a call. See [Summaries](summaries.md).
