# Translation

To get notes in another language, pick it under **Settings → Transcription → Translate to**. Each
note then gets a `## Translation` section above the original transcript, with the same times and
speakers, and `translation_language` in its frontmatter. The summary and title are written from
the translation, so they're in that language too. Recordings already in that language are left as
they are.

## Translation languages

Translation uses Apple's on-device translation models (the Translation framework), with Apple
Intelligence's more fluent translations on macOS 26.4 and later where it's turned on. None of the
speech models translate, so this is the model that was already on every Mac.

macOS downloads each language once and shares it with other apps: Settings shows whether the
languages from your transcription language (or your Mac's, for Automatic) are downloaded, with a
**Download** button. Download others under System Settings → General → Language & Region →
Translation Languages. If a recording's languages are missing, the note is saved without a
translation and Mixdown says which to download.
