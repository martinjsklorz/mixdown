# Translation

To get notes in another language, turn on **Settings → Translation → Translate recordings** and
pick the language under **Translate to**. Each note then gets a `## Translation` section above the original transcript, with the same times and
speakers, and `translation_language` in its frontmatter. The summary and title are written from
the translation, so they're in that language too. Recordings already in that language are left as
they are.

## Live translation

With a live model, the live text is translated as it's spoken too, so you can follow a call in a
language you don't speak. Each line's translation appears under it on Record, and the
[Dynamic Island](recording.md#the-dynamic-island)'s live text shows the translation instead of the
original. A line is translated once it has a few words, and again as it grows, so the translation
is a moment behind the speech.

Each line is translated on its own. With the transcription language on Automatic, its language is
told from the line, so lines already in the target language, such as yours in a call where only
the others speak another one, are left as they are. If the languages aren't downloaded, Record
says which.

Turn it off under **Settings → Translation → Translate live text while recording**. It doesn't
change the note: its translation is made afresh from the whole transcript once you stop.

## Translation languages

Translation uses Apple's on-device translation models (the Translation framework), with Apple
Intelligence's more fluent translations on macOS 26.4 and later where it's turned on. None of the
speech models translate, so this is the model that was already on every Mac.

macOS downloads each language once and shares it with other apps. The **Translate to** menu marks
with a green check the languages that are downloaded for recordings in your transcription language
(or your Mac's, for Automatic), like the speech model menu. Next to it, **Download** gets the chosen
language, and the trash button deletes it: macOS lets only System Settings remove translation
languages, so it opens System Settings → General → Language & Region, where **Translation
Languages** lists them. Download others there too. Settings makes sure of the chosen language by
translating a word, as macOS can say a language is downloaded after it was removed. If a recording's languages are missing, the note is saved without a
translation and Mixdown says which to download.
