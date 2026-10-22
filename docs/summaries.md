# Summaries

With Apple Intelligence turned on, each note starts with a summary: a short overview, the key
points and any action items, in the language of the recording (or of the
[translation](translation.md), if you translate notes).

Apple Intelligence writes it on your Mac after the transcript is ready, so the note takes a little
longer to appear. Nothing extra is downloaded, and the transcript doesn't leave your Mac. Long
recordings are summarized in parts, which are then combined. Action items are saved as Markdown
checkboxes (`- [ ]`), so you can tick them off in editors like Obsidian.

While recording with the live model, Apple Intelligence can also sum up just the last few
minutes, for when you drifted off. See [Catch up](recording.md#catch-up).

## Titles

The summary also names the note after its topic, e.g. "Release timeline". A call recorded from
Mixdown's call notification, or automatically, is titled as one in the language of the recording,
e.g. "Call about Release timeline" or "Anruf zu Budgetplanung". Recordings started any other way
aren't, even during a call.

Without a summary, the note is titled with the date and time it was recorded.

## Templates

Under **Settings → Summary**, pick a template for **Manual recordings** and one
for **Detected calls** (recordings started from the call notification or automatically):

- **General** (the default): overview, key points and action items, as above.
- **1:1**, **Standup** and **Client Call**: always the same four sections, `### TL;DR`,
  `### Decisions`, `### Action Items` (as `- [ ]` checkboxes) and `### Open Questions`, so every
  note of a kind reads the same. A section with nothing in it says _None._ Each template tells
  Apple Intelligence what to look out for, e.g. blockers in a standup or promises made to a
  client.

That template is preselected for each recording. To use another one for this recording only, pick
it on **Record** while recording or transcribing, until the summary starts.

## Turning summaries off

Untick **Settings → Summary → Summarize recordings**. That tab also says why summaries
aren't available on this Mac if they aren't. Without them, or if summarizing fails, the note is
saved with just the transcript.
