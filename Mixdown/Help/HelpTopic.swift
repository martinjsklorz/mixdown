import Foundation
import MixdownNotes

/// A page of Mixdown Help. The text is Markdown, rendered like a note. Links to
/// `mixdown-help:<topic>` open another topic.
enum HelpTopic: String, CaseIterable, Identifiable, Sendable {
    case gettingStarted = "getting-started"
    case recording
    case calls
    case notes
    case speechModels = "speech-models"
    case summaries
    case notifications
    case privacy
    case shortcuts
    case troubleshooting

    private static let urlScheme = "mixdown-help"

    var id: Self { self }

    /// The topic a `mixdown-help:<topic>` link points to.
    init?(url: URL) {
        guard url.scheme == Self.urlScheme else { return nil }
        self.init(rawValue: url.absoluteString.dropFirst(Self.urlScheme.count + 1).lowercased())
    }

    var title: String {
        switch self {
        case .gettingStarted: "Getting Started"
        case .recording: "Recording"
        case .calls: "Recording Calls"
        case .notes: "Notes"
        case .speechModels: "Speech Models"
        case .summaries: "Summaries"
        case .notifications: "Notifications and Sounds"
        case .privacy: "Privacy and Permissions"
        case .shortcuts: "Keyboard Shortcuts"
        case .troubleshooting: "Troubleshooting"
        }
    }

    var systemImage: String {
        switch self {
        case .gettingStarted: "star"
        case .recording: "record.circle"
        case .calls: "phone"
        case .notes: "doc.text"
        case .speechModels: "waveform"
        case .summaries: "sparkles"
        case .notifications: "bell.badge"
        case .privacy: "lock.shield"
        case .shortcuts: "keyboard"
        case .troubleshooting: "wrench.and.screwdriver"
        }
    }

    var blocks: [MarkdownBlock] { MarkdownBlock.parse(markdown) }

    // MARK: Search

    /// The topics matching every word of `query`, those matching in their title first. All topics
    /// for an empty query.
    static func search(_ query: String) -> [HelpTopic] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return allCases }

        func contains(_ text: String, _ word: String) -> Bool {
            text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let matches = allCases.filter { topic in
            words.allSatisfy { contains(topic.title, $0) || contains(searchText[topic] ?? "", $0) }
        }
        // A stable sort, so the topics keep their order otherwise.
        let inTitle = matches.filter { topic in words.allSatisfy { contains(topic.title, $0) } }
        return inTitle + matches.filter { !inTitle.contains($0) }
    }

    /// Each topic's text without Markdown, to search in.
    private static let searchText: [HelpTopic: String] = Dictionary(
        uniqueKeysWithValues: allCases.map { topic in
            (topic, topic.blocks.map(\.text).map(MarkdownBlock.plainText).joined(separator: " "))
        }
    )

    // MARK: Text

    var markdown: String {
        switch self {
        case .gettingStarted:
            """
            Mixdown records your microphone, whatever your Mac is playing (such as a call or a \
            video), or both at once, turns the speech into text, and saves it as a Markdown note. \
            Everything happens on your Mac. Your audio never leaves it.

            ## Set up

            The first time Mixdown opens, the setup assistant walks you through choosing a notes \
            folder, downloading a speech model, picking inputs and allowing the permissions. Open \
            it again with **Help → Setup Assistant…**.

            If you skipped it, open **Record** with the ● button next to the search field. Recording stays off until \
            these two are done:

            1. Click **Choose Folder…** and pick where your notes go, for example a new `Mixdown` \
            folder in Documents (use **New Folder** in the dialog).
            2. Click **Download Model** and wait for it to finish. The time left shows next to the \
            menu bar icon. See [Speech Models](mixdown-help:speech-models).

            ## Record

            1. Pick your inputs in the **Recording** menu: a microphone, **System Audio**, or both. \
            **Change…** next to the setup summary on Record does the same.
            2. Click the red button, or press ⌘R, to start recording.
            3. Click it again, or press ⌘R, to stop.

            A few seconds later the note appears under **Today** in the sidebar and opens. See \
            [Notes](mixdown-help:notes).

            ## Make it yours

            - **Settings → General → Launch Mixdown at login** keeps Mixdown in the menu bar.
            - **Settings → Design → Appearance** picks Auto, Light or Dark.
            - **Settings → Transcription** picks the speech model, the language and the names of \
            the speakers.
            """
        case .recording:
            """
            ## Start and stop

            - Click the red button on **Record**.
            - Choose **Recording → Start Recording** (⌘R).
            - Choose **Start Recording** from Mixdown's icon in the menu bar.
            - From any other app, press ⌃⌥⌘R. Change that shortcut or turn it off under \
            **Settings → General → Global Shortcuts**.

            Do the same again to stop. Recording carries on if you close the window.

            ## Pause

            Click the pause button beside Stop, or choose **Recording → Pause Recording** (⇧⌘P). \
            While paused, Mixdown records nothing, and macOS no longer shows the microphone in use. \
            Resume the same way to carry on in the same note; the paused time is left out of it.

            ## Mark a moment

            Press ⌃⌥⌘M in any app while recording, click the bookmark button beside Stop, or choose \
            **Recording → Mark Moment**. A field drops down under the notch, ready to type in: \
            write a few words, or none, and press Return to add the moment. Escape, clicking \
            elsewhere, or 5 seconds without typing drops it. The note lists each moment under \
            **Moments** at the end of its summary, with its time and what was being said.

            ## Catch up

            Drifted off? Press ⌃⌥⌘C in any app while recording, or choose **Recording → Catch Me \
            Up**. Apple Intelligence sums up the last few minutes of the live text in a few points, \
            in a card under the notch. It runs on your Mac, so nothing is sent anywhere and it costs \
            nothing. Click the card or press the shortcut again to close it; otherwise it closes once \
            you've had time to read it. It covers 5 minutes unless you choose otherwise under \
            **Settings → General → Global Shortcuts**. It needs the live model and Apple \
            Intelligence turned on, and is in the language the live text is translated into, if it \
            is.

            ## Inputs

            Pick inputs in the **Recording** menu, in the menu bar, or under **Settings → \
            Recording**. Choosing a microphone replaces the current one; choosing it again turns it \
            off, as long as System Audio stays on. At least one input stays on.

            **System Default**, the first microphone in the list, always records from the Mac's \
            current input: connect AirPods and Mixdown switches to them, take them out and it's back \
            on the built-in microphone. Pick a specific microphone instead to stay on it.

            Inputs can change while recording too, and the recording carries on. If a microphone you \
            picked disappears, Mixdown moves to the default one and returns to yours when it's back.

            ## While recording

            - **Record** shows a level meter for each input.
            - With **Settings → Design → Show recording in the Dynamic Island** on (the default), \
            the time and levels appear in a Dynamic Island around the camera notch instead of the \
            time in the menu bar. Without a notch, or with another display connected, the island \
            appears at the top center of the screen and the menu bar keeps the time too. Click the \
            island to open Record. With the setting off, the time shows in the menu bar.
            - If an input makes no sound for 10 seconds, Mixdown warns on Record and in the menu \
            bar. See [Troubleshooting](mixdown-help:troubleshooting).

            With the live model (the default), Record shows the words as you speak, and the note is \
            ready moments after you stop. Turn on **Settings → Design → Show live text** to see the \
            latest words scroll by in one line under the notch too. With an offline model, Mixdown \
            transcribes the recording when you stop and shows its progress on Record and in the \
            menu bar. Then the note opens.
            """
        case .calls:
            """
            Turn on both your microphone and **System Audio** to capture both sides of a call: your \
            voice through the microphone, everyone else through your Mac's speakers.

            Each input is transcribed on its own, then the lines are merged by time and labeled \
            **Me** and **Others**. Change the names under **Settings → Transcription → Speaker \
            Names**.

            Without headphones, your microphone also hears the other people through your speakers. \
            Mixdown takes that echo out of the microphone while both inputs record, and drops lines \
            it still recognizes as echo. Turn this off under **Settings → Recording → Echo**. \
            Headphones still give the cleanest result.

            ## Talk time

            While both inputs record, a ring next to the time in the Dynamic Island shows your \
            share of the talking in white and the others' in grey. The note ends with a **Talk \
            Time** table of how long each side talked in every minute, shown as a chart under the \
            note's date. Talk time goes by loudness, so music in the call counts as the others \
            talking. Turn the ring off under **Settings → Design → Show talk share**.

            ## When a call starts

            Mixdown notices when a call app (such as Zoom, Microsoft Teams, FaceTime, Slack or \
            Discord) or a browser has been using a microphone for a few seconds. Two switches \
            under **Settings → Recording → Calls** decide what happens:

            - **Notify when calls start and end** (on by default): a notification asks **Record \
            This Call?** Click it to record with System Audio turned on, plus your microphone if one \
            is selected. When the call ends, a notification asks **Stop Recording?**
            - **Record calls automatically** (off by default): recording starts by itself when a \
            call starts and stops when it ends. With notifications on, Mixdown says so. A \
            recording you started yourself keeps going when a call ends.

            With both off, calls aren't watched.
            """
        case .notes:
            """
            Your recordings are listed in the sidebar under **Today**, **Previous 7 Days** and then \
            each month. Pinned notes stay at the top under **Pinned**; click that heading to fold \
            them away or show them again. Search the sidebar (⌘F) to find older recordings.

            A small icon next to a note says how its recording started: a hand for one you started, \
            and the autostart icon for a call Mixdown recorded automatically.

            ## Working with a note

            The buttons above a note, right-clicking it in the sidebar, and the File and Edit menus \
            can:

            - **Pin** it to keep it at the top of the sidebar, and **Unpin** it again. This sets \
            `pinned: true` in the note's frontmatter.
            - **Rename** it. This changes both the title inside the note and its file name.
            - **Copy Transcript** as plain text.
            - **Share** it.
            - **Delete** it (⌘⌫, or Delete in the sidebar), which moves it to the Trash. Mixdown \
            asks first (turn that off under **Settings → General**), then shows a notification with \
            **Restore** to put the note back.

            Right-clicking also offers **Open in Default App**.

            ## Searching in Spotlight

            Your notes are in Spotlight (⌘Space), down to the line: searching for "release \
            timeline" shows the transcript line or action item that mentions it, with the note's \
            title and the time it was said. Click a result to open the note at that line. Turn it \
            off under **Settings → General → Show notes in Spotlight**.

            ## The notes folder

            Each note is a Markdown file in the folder you chose. Open it with **File → Open Notes \
            Folder** (⇧⌘O), and change it under **Settings → General**. Notes work with any \
            Markdown editor, such as Obsidian. Action items are saved as checkboxes (`- [ ]`) you \
            can tick off there. Notes you file into subfolders are listed too, with their folder \
            under the title; hidden folders such as Obsidian's `.obsidian` are skipped.

            If the folder can't be reached, for example because it's on a drive that isn't \
            connected, Mixdown says so and doesn't record until it's back or you choose another \
            folder. A note finished while the folder was away is kept until it can be saved: \
            Mixdown tries again every 30 seconds and as soon as you choose another folder. Keep \
            Mixdown open until then; it warns you if you quit first.
            """
        case .speechModels:
            """
            Mixdown turns speech into text with a model that runs on your Mac. Choose one under \
            **Settings → Transcription**, in one of two kinds:

            - **Live** models transcribe while you record, so the note is ready when you stop. The \
            audio isn't kept, so an hours-long meeting takes no more memory than a short one.
            - **Offline** models transcribe the whole recording once you stop, keeping its audio in \
            memory until then. Qwen3 and MOSS are more accurate than the live model.

            The models:

            - **Nemotron 3.5 ASR Streaming 0.6B** (live, the default, about 540 MB): long meetings, \
            with the text as you speak.
            - **Qwen3-ASR 0.6B** (about 0.9 GB): fast, everyday notes.
            - **Qwen3-ASR 1.7B** (about 2.3 GB): better accuracy, on Macs with 24 GB of memory or \
            more.
            - **MOSS Transcribe Diarize 0.9B** (about 1 GB): meetings, because it labels who is \
            speaking.
            - **Apple Speech**: Apple's own model, the one Notes and Voice \
            Memos use. macOS downloads it once per language and shares it with other apps. It \
            doesn't detect the language: **Automatic** uses your Mac's language.

            ## Downloading

            A model is downloaded once, with **Download Model** on Record, in the Recording menu \
            or in Settings. After switching models, download the new one before recording. \
            **Cancel Download** stops it; files already fetched are kept, so the next download picks \
            up where it left off.

            The model menu under **Settings → Transcription** marks downloaded models with a green \
            check. To free up disk space, select a model there and click the trash button next to \
            the menu. You'll need to download it again before recording with it. Apple Speech \
            belongs to macOS, which removes it when no app needs it any more, so it has no trash \
            button.

            ## Speakers

            With MOSS, speaker numbers start over every 10 minutes, so "Speaker 1" may be someone \
            else later in a long recording. The other models, Apple Speech included, don't tell \
            speakers apart.
            """
        case .summaries:
            """
            With Apple Intelligence turned on, each note starts with a summary: a short overview, \
            the key points and any action items, in the language of the recording. Apple \
            Intelligence writes it on your Mac, so the transcript doesn't leave it.

            The summary also names the note after its topic, e.g. "Release timeline". Calls \
            recorded from Mixdown's call notification, or automatically, are titled as calls, e.g. \
            "Call about Release timeline". Without a summary, a note is titled with the date and \
            time it was recorded.

            ## Templates

            Under **Settings → Transcription**, pick a summary template for manual recordings and \
            one for detected calls (recordings started from the call notification or \
            automatically). **General** is the overview, key points and action items above. \
            **1:1**, **Standup** and **Client Call** always have the same four sections: TL;DR, \
            Decisions, Action Items (as checkboxes) and Open Questions. A section with nothing in \
            it says _None._

            That template is preselected for each recording. To use another one for this \
            recording only, pick it on **Record** while recording or transcribing, until the \
            summary starts.

            Turn summaries off under **Settings → Transcription → Summarize recordings**. That \
            section also says why summaries aren't available on this Mac if they aren't.

            ## Translation

            To get notes in another language, pick it under **Settings → Transcription → \
            Translate to**. Each note then has a translation above the original transcript, and \
            its summary and title are in that language. Recordings already in that language are \
            left as they are.

            Apple's translation models translate on your Mac, with Apple Intelligence where it's \
            on. macOS downloads each language once: click **Download** next to the languages in \
            Settings, or download others under System Settings → General → Language & Region → \
            Translation Languages. If they're missing, the note is saved without a translation and \
            Mixdown says which to download.

            ### Live translation

            With the live model, the live text is translated as it's spoken too: each line's \
            translation appears under it on Record, and the line under the notch shows the \
            translation instead. It's a line or so behind, catching up as the line grows. Lines \
            already in that language are left as they are, so in a call where only the others speak \
            another language, only their lines are translated. Turn it off under **Settings → \
            Transcription → Translate live text while recording**. The note's translation is made \
            afresh from the whole transcript once you stop.
            """
        case .notifications:
            """
            Mixdown uses notifications to say a note is ready (with **Open** and **Show in \
            Finder**), to confirm copying a transcript, to offer **Restore** after moving a note to \
            the Trash, and about calls. To turn them all off, untick **Settings → Notifications → \
            Show notifications**.

            If notifications are off for Mixdown in System Settings, Settings says so and has a \
            button to open them.

            ## Sounds

            Short sounds mark recording starting, pausing, resuming and stopping, a note being \
            ready, and something going wrong, so you can tell without looking. Pick a different sound, \
            or **None**, for each under **Settings → Notifications → Sounds**, or untick **Play \
            sounds**.

            Sounds aren't recorded from system audio, but without headphones your microphone may \
            hear the start sound.
            """
        case .privacy:
            """
            Mixdown records, transcribes and summarizes on your Mac. Your audio and transcripts \
            never leave it. Only the speech models are downloaded.

            ## Permissions

            The first time, macOS asks for permission:

            - **Microphone**, to record your voice.
            - **System Audio Recording**, to record what your Mac plays.

            Change them in System Settings › Privacy & Security. System audio is under Screen & \
            System Audio Recording › System Audio Recording Only.
            """
        case .shortcuts:
            """
            - ⌘R: Start or stop recording
            - ⇧⌘P: Pause or resume recording
            - ⌃⌥⌘R: Start or stop recording from any app (change it under **Settings → General**)
            - ⌃⌥⌘M: Mark a moment while recording, from any app (change it under **Settings → General**)
            - ⌃⌥⌘C: Catch up on the last few minutes while recording, from any app (change it under \
            **Settings → General**)
            - ⌘1: Show Record
            - ⌘2: Show Notes
            - ⌘F: Search recordings
            - ⌘0: Open the Mixdown window
            - ⇧⌘O: Open the notes folder
            - ⌘⌫: Move the open note to the Trash
            - ⌘,: Open Settings
            - ⌘?: Open Mixdown Help
            """
        case .troubleshooting:
            """
            ## System audio is silent

            macOS records silence rather than giving an error when Mixdown isn't allowed to record \
            system audio. Turn Mixdown on in System Settings › Privacy & Security › Screen & System \
            Audio Recording › System Audio Recording Only. **Open Privacy Settings…** in the menu \
            bar takes you there when Mixdown warns about a silent input.

            ## A microphone is silent

            Check that Mixdown is on in System Settings › Privacy & Security › Microphone, and that \
            the microphone isn't muted.

            ## Recording won't start

            Record says what's missing: choose a notes folder, download the speech model, or \
            reconnect the drive the notes folder is on.

            ## A note hasn't been saved yet

            The notes folder couldn't be reached when the note was finished. Connect the folder's \
            drive, or choose another folder under **Settings → General**, and Mixdown saves it. \
            Quitting before then loses the note. See [Notes](mixdown-help:notes).

            ## The speech model is downloading again

            The model was removed while Mixdown was recording, for example Apple Speech, which \
            macOS removes when it thinks no app needs it. Mixdown downloads it again before \
            transcribing, and the note follows once that's done. This download can't be \
            cancelled, because the recording is waiting on it.

            ## The other people show up as "Me"

            Your microphone heard them through the speakers. Wear headphones. See \
            [Recording Calls](mixdown-help:calls).

            ## Mixdown doesn't offer to record calls

            Check **Settings → Recording → Calls** and **Settings → Notifications → Show \
            notifications**, and that notifications are allowed for Mixdown in System Settings › \
            Notifications. None appears while Mixdown is already recording.
            """
        }
    }
}

extension MarkdownBlock {
    /// The block's text, empty for a rule.
    fileprivate var text: String {
        switch self {
        case .heading(_, let text), .paragraph(let text), .listItem(_, _, let text), .quote(let text),
            .code(_, let text):
            text
        case .rule:
            ""
        }
    }
}
