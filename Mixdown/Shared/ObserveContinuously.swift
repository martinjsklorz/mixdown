import Observation

/// Hands `onValue` what `read` returns now, and again after every change to what it read, for as
/// long as `owner` lives. `withObservationTracking` only fires once, so this registers again on
/// each change, after a hop to the main actor, seeing every change one at a time (unlike
/// `Observations`, which coalesces them).
///
/// `read` and `onValue` get `owner` rather than capturing it, so they don't keep it alive.
@MainActor
func observeContinuously<Owner: AnyObject & Sendable, Value>(
    _ owner: Owner,
    read: @escaping @MainActor @Sendable (Owner) -> Value,
    onValue: @escaping @MainActor @Sendable (Owner, Value) -> Void
) {
    let value = withObservationTracking {
        read(owner)
    } onChange: { [weak owner] in
        Task { @MainActor in
            guard let owner else { return }
            observeContinuously(owner, read: read, onValue: onValue)
        }
    }
    onValue(owner, value)
}
