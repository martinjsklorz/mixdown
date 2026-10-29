import CoreAudio
import Foundation
import MixdownCore
import os

/// What `MicrophoneInput` and `SystemAudioTap` share about their listeners and teardown.
///
/// All of a source's listeners run on `listenerQueue`, so reading a new format and publishing it
/// to the `FormatHistory` happen in the order the notifications came in. And once the audio
/// service has restarted, the source's HAL objects are gone with it and their IDs may belong to
/// other devices by now, so teardown must leave them alone.
///
/// `Sendable`: the state is behind a lock.
final class CaptureSourceLifecycle: Sendable {
    private struct State: Sendable {
        var serviceRestarted = false
        var isInvalidated = false
        var formatCheck: (@Sendable () -> Void)?
    }

    /// The serial queue every listener of the source runs on.
    let listenerQueue = DispatchQueue(label: "app.mixdown.audio.capture-listener", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Whether the source is still recording from the HAL objects it set up: it hasn't been
    /// invalidated and the audio service hasn't restarted.
    var isLive: Bool {
        state.withLock { !$0.serviceRestarted && !$0.isInvalidated }
    }

    /// A listener for the audio service restarting, which takes the IO proc down without a word
    /// from the device. Marks the restart before it reports `.audioServiceRestarted`.
    func serviceRestartListener(onFailure: @escaping @Sendable (AudioCaptureError) -> Void) -> HALPropertyListener {
        HALPropertyListener(selectors: [kAudioHardwarePropertyServiceRestarted], queue: listenerQueue) {
            [weak self] in
            self?.markServiceRestarted()
            onFailure(.audioServiceRestarted)
        }
    }

    func markServiceRestarted() {
        state.withLock { $0.serviceRestarted = true }
    }

    /// Sets what `checkFormat` runs: usually the source's format listener.
    func setFormatCheck(_ check: @escaping @Sendable () -> Void) {
        state.withLock { $0.formatCheck = check }
    }

    /// Reads the format again on `listenerQueue`, as if its listener had fired. Does nothing
    /// before the source has started or after it's invalidated.
    func checkFormat() {
        guard let check = state.withLock({ $0.formatCheck }) else { return }
        listenerQueue.async(execute: check)
    }

    /// Marks the source as torn down. Returns whether its HAL objects are still its own to stop
    /// and destroy, which they aren't once the audio service has restarted.
    func invalidate() -> Bool {
        state.withLock { state in
            state.isInvalidated = true
            state.formatCheck = nil
            return !state.serviceRestarted
        }
    }
}
