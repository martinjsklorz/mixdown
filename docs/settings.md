# Settings

Press ⌘, or click the cog above the sidebar to open Settings. **Settings…** in the menu bar opens it too.

## General

- **Notes → Folder**: where notes are saved. **Choose…** picks another, **Show in Finder** opens
  it, and **Try Again** looks for it again when it can't be reached. See
  [Notes](notes.md#the-notes-folder).
- **Ask before deleting a note**: on by default.
- **Show notes in Spotlight**: on by default. Each line of a note shows up in Spotlight; see
  [Searching in Spotlight](notes.md#searching-in-spotlight).
- **Chat → Chat with your notes**: on by default. Off, Chat leaves the sidebar and the View menu,
  and Mixdown stops reading your notes for it. See [Chat](chat.md).
- **Global Shortcuts → Start and stop recording from any app**: on by default, with ⌃⌥⌘R. Click
  the shortcut and press new keys to change it.
- **Global Shortcuts → Mark moment while recording**: ⌃⌥⌘M. Clear it to turn it off. See
  [Recording](recording.md#mark-a-moment).
- **Global Shortcuts → Catch me up while recording**: ⌃⌥⌘C. Clear it to turn it off.
  **Catch up on the last** sets how many minutes it sums up: 1, 2, 5 (the default), 10 or 15. See
  [Recording](recording.md#catch-up).
- **Startup → Launch Mixdown at login**. If macOS needs your approval, allow Mixdown in System
  Settings › General › Login Items.
- **Updates → Check for updates automatically** and **Download and install updates
  automatically**, which needs the first on. **Check Now** looks right away. Checking sends only
  the app's version; updates downloaded automatically are installed when you quit.

## Recording

- **Inputs**: the microphone (or none) and **Record system audio**. Changes apply right away, even
  while recording. See [Recording](recording.md#inputs).
- **Echo**: **Remove echo from the microphone**: on by default. See
  [Recording calls](calls.md#echo).
- **Talk Time**: **Measure talk time**: off by default. Shown with **Echo** when system audio can
  be recorded. See [Recording calls](calls.md#talk-time).
- **Silence**: **Ask if still recording after** 5, 10, 15 (the default), 30 or 60 minutes without
  speech, or **Never**. See [Recording](recording.md#while-recording).
- **Audio**: **Keep audio until the note is saved** **On Disk** (the default) or **In Memory
  Only**. See [Privacy](privacy.md).
- **Calls**: **Notify when calls start and end** (on) and **Record calls automatically** (off).
  **Apps that count as calls → Choose…** picks which apps do, and adds others. See
  [Recording calls](calls.md#call-detection).

## Transcription

- **Model**: the speech model, with buttons to download, cancel, retry or delete it. See
  [Speech models](speech-models.md).
- **Language**: **Automatic** or a specific language.
- **Speaker Names**: the labels for the microphone (**Me**) and system audio (**Others**) when you
  record both.
- **Speakers → Tell speakers apart**: off by default. Labels the people on the system audio
  Speaker 1, Speaker 2 and so on, once a recording ends. It needs the speaker model (about
  100 MB), with buttons to download, cancel, retry or delete it.
- **Speakers → Name speakers from the conversation**: on by default, with **Tell speakers apart**
  on. Your summary model looks for names said in the recording.

## Summary

- **Summarize recordings**: on by default. If summaries can't be made, e.g. because Apple
  Intelligence is off or the model isn't downloaded yet, the tab says why.
- **Generate note title**: on by default. Names each note after the topic of its summary. Off,
  notes are named after the time they were recorded, or an imported file's name.
- **Templates**: **Manual recordings** and **Detected calls**, the template for each.
- **Model**: Apple Intelligence, or an open model such as Qwen3 that runs on your Mac with MLX,
  with a **Download** button until it's downloaded. See [Summaries](summaries.md#models).

## Templates

The templates summaries are made with: change one, or add your own with **+**. A template has a
name, its sections and instructions on what kind of recording it's for and what to look out for.
**Restore Default** undoes your changes to a built-in template. See
[Summaries](summaries.md#templates).

## Translation

- **Translate recordings**: off by default.
- **Translate to**: a language, and whether macOS has downloaded the languages to translate your
  recordings, with a **Download** button.
- **Translate live text while recording**: on by default, with a live model. Translates the live
  text as it's spoken. See [Translation](translation.md).

## Vocabulary

- Words the speech model gets wrong: **Write as** how each is written and **Heard as** what the
  model writes instead, separated by commas. **Add Word** adds a row, the minus button removes one.
- **Fuzzy**: off by default. **Strict** or **Loose** also corrects spellings close to **Write as**
  in new recordings and adds them to **Heard as**. See
  [Speech models](speech-models.md#fuzzy-matching).
- **Import…** and **Export…**: the words as a JSON file. Import also reads Muesli's custom words.
  See [Speech models](speech-models.md#import-and-export).
- **Correct Existing Notes…** makes the same corrections in every note in the notes folder. See
  [Speech models](speech-models.md#vocabulary).

## Notifications

- **Show notifications**: on by default. While it's on, **Permission** shows whether macOS lets
  Mixdown notify, with **Allow…** if it hasn't asked yet and **Open System Settings** if they
  were turned off there.
- **Sounds**: **Play sounds**, and a sound for each moment. See
  [Notifications and sounds](notifications-and-sounds.md).

## Design

- **Appearance**: Auto, Light or Dark. Auto follows System Settings.
- **Show recording in the Dynamic Island**: on by default, with which side the time goes on,
  **Show input levels**, **Show live text** and **Show talk share**. See
  [Recording](recording.md#the-dynamic-island) and [Recording calls](calls.md#talk-time). **Show
  talk share** needs **Measure talk time** on.
