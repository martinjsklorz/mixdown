# Summaries

Each note starts with a summary: a short overview, the key points and any action items, in the
language of the recording (or of the [translation](translation.md), if you translate notes).

The [summary model](#models) writes it on your Mac after the transcript is ready, so the note takes
a little longer to appear, and the transcript doesn't leave your Mac. Long recordings are
summarized in parts, which are then combined. Action items are saved as Markdown checkboxes
(`- [ ]`), so you can tick them off in editors like Obsidian.

While recording with the live model, the summary model can also sum up just the last few minutes,
for when you drifted off. See [Catch up](recording.md#catch-up).

## Models

Pick the model under **Settings → Summary → Model**:

- **Apple Intelligence** (the default): part of macOS, so nothing is downloaded. It needs Apple
  Intelligence turned on in System Settings.
- **Open models**, run on your Mac with MLX, for Macs without Apple Intelligence or for summaries
  that follow the transcript more closely. Each is downloaded once from Hugging Face: pick it, then
  click **Download**. The menu marks downloaded models with a green check, and the trash button
  deletes one again.

  | Model | Download | |
  | --- | --- | --- |
  | Qwen3 1.7B | 1 GB | Fast, plainer summaries |
  | Qwen3 4B Instruct | 2.3 GB | Balanced; a good first choice |
  | Qwen3.5 4B | 3 GB | The newer generation at the same size |
  | Qwen3 8B | 4.6 GB | Best summaries, twice the memory and time |

  An open model needs about as much free memory as its download while it summarizes, and is
  unloaded again shortly after. Models are kept with the speech models, in
  `~/Library/Containers/app.mixdown.Mixdown/Data/Library/Application Support/Mixdown/Models`.

The model you pick also does [Catch up](recording.md#catch-up). [Chat](chat.md) always uses Apple
Intelligence.

## Titles

The summary also names the note after its topic, e.g. "Release timeline". A call recorded from
Mixdown's call notification, or automatically, is titled as one in the language of the recording,
naming its app, e.g. "Zoom call about Release timeline" or "FaceTime-Anruf zu Budgetplanung". Calls
in a browser leave the browser out: "Call about Release timeline". Recordings started any other way
aren't, even during a call.

Without a summary, the note is titled with the date and time it was recorded.

## Templates

Under **Settings → Summary**, pick a template for **Manual recordings** and one
for **Detected calls** (recordings started from the call notification or automatically):

- **General** (the default): overview, key points and action items, as above.
- **1:1**, **Standup** and **Client Call**: always the same four sections, `### TL;DR`,
  `### Decisions`, `### Action Items` (as `- [ ]` checkboxes) and `### Open Questions`, so every
  note of a kind reads the same. A section with nothing in it says _None._ Each template tells
  the model what to look out for, e.g. blockers in a standup or promises made to a
  client.

Under **Settings → Templates**, change a template or add your own with **+**. A template has a
name, its sections (either of the two layouts above) and instructions: what kind of recording
it's for and what to look out for, e.g. "The recording is a sprint review. Look out for what was
shown and the feedback on it." **Restore Default** undoes your changes to a built-in template.
Deleting one of yours leaves the notes summarized with it as they are.

That template is preselected for each recording. To use another one for this recording only, pick
it on **Record** while recording or transcribing, until the summary starts.

## Turning summaries off

Untick **Settings → Summary → Summarize recordings**. That tab also says why summaries
aren't available on this Mac if they aren't. Without them, or if summarizing fails, the note is
saved with just the transcript.
