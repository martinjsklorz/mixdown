# Keyboard shortcuts

| Shortcut | Action |
| -------- | ------ |
| ⌘R | Start or stop recording |
| ⇧⌘P | Pause or resume recording |
| ⌃⌥⌘R | Start or stop recording from any app (change it under **Settings → General**) |
| ⌃⌥⌘M | Mark a moment while recording, from any app (change it under **Settings → General**) |
| ⌃⌥⌘C | Catch up on the last few minutes while recording, from any app (change it under **Settings → General**) |
| ⌘1 | Show Record |
| ⌘2 | Show Notes |
| ⌘3 | Show Chat |
| ⌘F | Search recordings |
| ⌘0 | Open the Mixdown window |
| ⇧⌘O | Open the notes folder |
| ⇧⌘I | Import an audio or video file as a note |
| ⌘⌫ | Delete the open note (move it to the Trash) |
| ⌘, | Open Settings |
| ⌘? | Open Mixdown Help |

**Help → Keyboard Shortcuts** shows this list in the app.

## Links for other apps

Raycast, Stream Deck, Keyboard Maestro, Shortcuts and scripts can control Mixdown with
`mixdown://` links:

| Link | Action |
| ---- | ------ |
| `mixdown://toggle` | Start or stop recording, like ⌃⌥⌘R |
| `mixdown://start` | Start recording (does nothing while recording) |
| `mixdown://stop` | Stop recording (does nothing when not recording) |
| `mixdown://pause` | Pause the recording |
| `mixdown://resume` | Resume the recording |
| `mixdown://toggle-pause` | Pause or resume the recording |
| `mixdown://mark` | Mark a moment and write a few words about it under the notch, like ⌃⌥⌘M |
| `mixdown://mark?text=Follow%20up` | Mark a moment with these words, without the field |
| `mixdown://open` | Open the Mixdown window |
| `mixdown://open?note=latest` | Open the newest note |
| `mixdown://open?note=Weekly%20Sync` | Open the newest note with this title |
| `mixdown://open?note=Clients/Acme/2026-10-24%200930%20Weekly%20Sync` | Open a note by its path in the notes folder (`.md` optional), or by its full path |

Encode spaces and other special characters in `text` and `note` as in any link (`%20` for a
space). Pausing, resuming and marking a moment beep when Mixdown isn't recording, and opening a
note that isn't in the notes folder beeps and shows Notes.

To keep the app you're in at the front, open the link in the background: `open -g mixdown://toggle`
in Terminal or a shell script action.
