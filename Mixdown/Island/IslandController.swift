import AppKit
import KeyboardShortcuts
import MixdownCore
import Observation

/// What shows around the notch while recording: the Dynamic Island, the field for marking a
/// moment, and the Catch Me Up card. Takes the Mark Moment and Catch Me Up shortcuts while
/// recording, so other apps get those keys otherwise.
@MainActor @Observable
final class IslandController {
    /// Whether the Dynamic Island is showing the recording time where it can always be seen, so
    /// the menu bar leaves it out. See `DynamicIsland.showsTimeAlone`.
    private(set) var showsTimeAlone = false
    /// The moment just marked while the user writes a note on it under the notch; `nil` once the
    /// field closes. See `markMoment()`.
    private var momentDraft: MomentDraft?
    /// The catch-up asked for last, while it's summed up and shown under the notch; `nil` once
    /// its card closes. See `catchUp()`.
    private var catchUpRequest: CatchUpRequest?

    /// Set by `start(environment:openRecorder:)`.
    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private var openRecorder: () -> Void = {}
    /// Created the first time it's shown.
    @ObservationIgnored private var dynamicIsland: DynamicIsland?
    /// The field for `momentDraft`. Created the first time it's shown.
    @ObservationIgnored private var momentEntry: MomentEntry?
    /// Closes the field for `momentDraft` if nothing is typed in time.
    @ObservationIgnored private var momentDraftTimeout: Task<Void, Never>?
    /// The card for `catchUpRequest`. Created the first time it's shown.
    @ObservationIgnored private var catchUpCard: CatchUpCard?
    /// Sums up `catchUpRequest`, then closes its card once it's had time to be read.
    @ObservationIgnored private var catchingUp: Task<Void, Never>?

    /// Starts showing what `environment` records, and listening for the shortcuts. `openRecorder`
    /// opens Record in the main window, for clicks on the island.
    func start(environment: AppEnvironment, openRecorder: @escaping () -> Void) {
        self.environment = environment
        self.openRecorder = openRecorder
        observeDynamicIsland()
        observeMoments()
        observeCatchUp()
        listenForMomentShortcut()
        listenForCatchUpShortcut()
    }

    // MARK: Observation
    //
    // Like `AppEnvironment`'s, each `observe…` method reads what it depends on in
    // `withObservationTracking`, acts on it, and re-registers itself on the next change.

    /// Shows the Dynamic Island while recording, if it's turned on, and lays it out again when its
    /// settings change.
    private func observeDynamicIsland() {
        guard let environment else { return }
        let (shows, layout) = withObservationTracking {
            let coordinator = environment.coordinator
            let preferences = environment.preferences
            var layout = preferences.islandLayout
            // Only a live model has words to show while recording.
            layout.showsLiveText = layout.showsLiveText && coordinator.showsLiveTranscript
            return (coordinator.isRecording && preferences.showsRecordingInDynamicIsland, layout)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeDynamicIsland() }
        }
        if shows {
            let island =
                dynamicIsland
                ?? DynamicIsland(
                    environment: environment,
                    openRecorder: openRecorder,
                    showsTimeAloneChanged: { [weak self] in self?.showsTimeAlone = $0 }
                )
            dynamicIsland = island
            island.show(layout)
        } else {
            dynamicIsland?.hide()
        }
        // The field and the card go under the island while it's shown, else under the notch.
        momentEntry?.islandMoved()
        catchUpCard?.islandMoved()
    }

    /// Takes the Mark Moment shortcut only while recording, so other apps get those keys
    /// otherwise, and shows the field for `momentDraft` while there is one. A recording that
    /// stops closes the field, dropping a moment not yet added with Return.
    private func observeMoments() {
        guard let environment else { return }
        let (isRecording, draft) = withObservationTracking {
            (environment.coordinator.isRecording, momentDraft)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMoments() }
        }
        if isRecording {
            KeyboardShortcuts.enable(.markMoment)
        } else {
            KeyboardShortcuts.disable(.markMoment)
            closeMomentDraft()
        }
        if let draft, isRecording {
            let entry =
                momentEntry
                ?? MomentEntry(island: self, islandFrame: { [weak self] in self?.dynamicIsland?.frame })
            momentEntry = entry
            entry.show(draft)
        } else {
            momentEntry?.hide()
        }
    }

    /// Takes the Catch Me Up shortcut only while recording, so other apps get those keys
    /// otherwise, and shows the card for `catchUpRequest` while there is one. A recording that
    /// stops closes the card.
    private func observeCatchUp() {
        guard let environment else { return }
        let (isRecording, request) = withObservationTracking {
            (environment.coordinator.isRecording, catchUpRequest)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeCatchUp() }
        }
        if isRecording {
            KeyboardShortcuts.enable(.catchUp)
        } else {
            KeyboardShortcuts.disable(.catchUp)
            closeCatchUp()
        }
        if let request, isRecording {
            let card =
                catchUpCard
                ?? CatchUpCard(island: self, islandFrame: { [weak self] in self?.dynamicIsland?.frame })
            catchUpCard = card
            card.show(request)
        } else {
            catchUpCard?.hide()
        }
    }

    // MARK: Moments

    /// How long the field for a new moment waits for typing before it closes.
    private static let momentDraftTimeoutDuration = Duration.seconds(5)

    /// Starts on the Mark Moment shortcut, from any app. `observeMoments()` takes it only while
    /// recording.
    private func listenForMomentShortcut() {
        KeyboardShortcuts.onKeyUp(for: .markMoment) { [weak self] in
            self?.markMoment()
        }
        KeyboardShortcuts.disable(.markMoment)
    }

    /// Marks the point the recording has reached, and opens a field under the notch to write a
    /// few words about it. Return adds the moment to the note; Escape, clicking elsewhere, or
    /// `momentDraftTimeoutDuration` without typing drops it. Beeps when not recording.
    func markMoment() {
        guard let time = environment?.coordinator.momentTime else {
            NSSound.beep()
            return
        }
        // Both would go under the notch.
        closeCatchUp()
        let draft = MomentDraft(time: time)
        momentDraft = draft
        momentDraftTimeout?.cancel()
        momentDraftTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.momentDraftTimeoutDuration)
            guard let self, !Task.isCancelled, self.momentDraft === draft, draft.text.isEmpty else { return }
            self.closeMomentDraft()
        }
    }

    /// Adds `momentDraft` to the note, with what was typed, and closes its field.
    func addMomentDraft() {
        guard let momentDraft else { return }
        environment?.coordinator.addMoment(at: momentDraft.time, text: momentDraft.text)
        closeMomentDraft()
    }

    /// Closes the field for `momentDraft`, dropping the moment unless it was added.
    func closeMomentDraft() {
        guard momentDraft != nil else { return }
        momentDraft = nil
        momentDraftTimeout?.cancel()
        momentDraftTimeout = nil
    }

    // MARK: Catch Me Up

    /// How long a catch-up stays up once it's in: long enough to read, at about three words a
    /// second, and at least 15 seconds. A failure, which only says why, goes sooner.
    private static func catchUpReadingTime(for state: CatchUpRequest.State) -> Duration {
        switch state {
        case .summarizing:
            return .zero
        case .ready(let catchUp):
            let words = catchUp.points.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
            return max(.seconds(15), .seconds(5) + .milliseconds(words * 350))
        case .failed:
            return .seconds(8)
        }
    }

    /// Starts on the Catch Me Up shortcut, from any app. `observeCatchUp()` takes it only while
    /// recording.
    private func listenForCatchUpShortcut() {
        KeyboardShortcuts.onKeyUp(for: .catchUp) { [weak self] in
            self?.catchUp()
        }
        KeyboardShortcuts.disable(.catchUp)
    }

    /// Has Apple Intelligence sum up the last `Preferences.catchUpMinutes` of the live text, on
    /// this Mac, in a card under the notch, for when the user drifted off. If the card is open already, closes
    /// it instead. It closes by itself once it's had time to be read, unless the pointer is over
    /// it. Beeps when not recording.
    func catchUp() {
        guard catchUpRequest == nil else {
            closeCatchUp()
            return
        }
        guard let environment, environment.coordinator.isRecording else {
            NSSound.beep()
            return
        }
        // Both would go under the notch.
        closeMomentDraft()
        let request = CatchUpRequest(minutes: environment.preferences.catchUpMinutes)
        catchUpRequest = request
        catchingUp = Task { [weak self, coordinator = environment.coordinator, summarizer = environment.summarizer] in
            do {
                let catchUp = try await coordinator.catchUp(
                    onLast: TimeInterval(request.minutes * 60),
                    with: summarizer
                )
                request.state = .ready(catchUp)
                Self.announce(catchUp.points.joined(separator: " "))
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                let message: String
                if case SummarizationError.unavailable(let reason) = error {
                    // What to turn on, without "Summaries aren't available".
                    message = reason
                } else {
                    message = error.localizedDescription
                }
                request.state = .failed(message)
                Self.announce(message)
            }
            try? await Task.sleep(for: Self.catchUpReadingTime(for: request.state))
            // Not while it's being read.
            while !Task.isCancelled, request.isHovered {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, let self, self.catchUpRequest === request else { return }
            self.closeCatchUp()
        }
    }

    /// Closes the card for `catchUpRequest`, stopping the catch-up if it's still being summed up.
    func closeCatchUp() {
        guard catchUpRequest != nil else { return }
        catchUpRequest = nil
        catchingUp?.cancel()
        catchingUp = nil
    }

    /// Reads `text` out with VoiceOver, as the card never has the focus.
    private static func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}
