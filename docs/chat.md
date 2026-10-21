# Chat

Ask questions across all your notes, like "What did we decide about the release?" or "What did
Anna say about the budget?", under **Chat** (⌘3, or the speech bubbles next to Record at the top
of the sidebar). Apple Intelligence answers on your Mac from the lines of your notes that match the
question best, and nothing leaves your Mac.

## Citations

Each statement in an answer cites the lines it comes from, as small numbers. Below the answer,
each cited line is listed with its note's title, date and the time it was said. Click a number or
a line to open the note scrolled to that line, highlighted for a moment. **⌘3** takes you back to
the chat.

Answers only use what's in your notes. If nothing in them answers the question, Chat says so.

## Counting

Questions that ask how many, like "How many 1:1s did I have in September?" or "Wie viele Anrufe
hatte ich letzte Woche?", are counted by Mixdown itself, not by Apple Intelligence, so the number
is exact. The answer lists the notes it counted, and how long they run together.

Mixdown understands, in English and German:

- **When**: today, yesterday, this or last week, month or year, the last 7 days, a month (with or
  without a year: "September" is the latest one), a year, or "since August".
- **What kind**: 1:1s, standups and client calls are notes summarized with that
  [template](summaries.md#templates), or with it in their title, like "1:1 Anna". Calls are
  recordings started from the call notification or automatically, client calls, and notes titled
  as a call ("Call about …"). Without a kind, every note counts.
- **About what**: "how many calls mentioned the budget?" or "how many 1:1s with Anna?" counts the
  notes that contain those words.

## How Chat finds the lines

The first time you open Chat, Mixdown reads your notes in short passages of a few lines and
turns each into an embedding of its meaning with Apple's on-device language models (macOS
downloads the model the first time). It says how far it's got; you can ask while it reads, but
answers may miss the notes it hasn't read yet. After that, only new and changed notes are read
again, also after relaunching.

A question is matched against the passages by its words and by its meaning, so "When do we
ship?" finds "The release moves to Friday." Dates and kinds in a question narrow down the notes
it looks in: "What did we decide in last week's standups?" only looks at last week's standups.
Short follow-ups like "And what about Ben?" are read together with the question before.

## Without Apple Intelligence

If Apple Intelligence is off or not available on this Mac, Chat says why. It still counts notes
exactly, and shows the lines that match a question best.

**New Chat** in the toolbar starts over. The chat lasts until you quit Mixdown.
