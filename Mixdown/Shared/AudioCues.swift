import AppKit
import MixdownCore

/// Plays the sound chosen for each `AudioCue` under Settings → Notifications, unless sounds are off.
///
/// Uses `NSSound`, which plays from Mixdown's own process. The system audio tap leaves that
/// process out, so cues don't end up in the Others track. A microphone near the speakers can
/// still pick them up.
@MainActor
enum AudioCues {
    static func play(_ cue: AudioCue, settings: AppSettings = AppSettings()) {
        guard settings.playsSounds, let name = settings.sound(for: cue) else { return }
        play(named: name)
    }

    /// Plays a sound by name, e.g. "Tink", starting over if it's already playing.
    static func play(named name: String) {
        guard !name.isEmpty, let sound = NSSound(named: NSSound.Name(name)) else { return }
        // `NSSound(named:)` hands out one shared instance per name, which won't play twice at once.
        sound.stop()
        sound.play()
    }

    /// The names of the sounds macOS comes with, plus any installed for all users, for choosing
    /// from. The sandbox hides the user's own `~/Library/Sounds`.
    static let availableSounds: [String] = {
        let folders = ["/System/Library/Sounds", "/Library/Sounds"]
        let names = folders.flatMap { folder in
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            return files.map { ($0 as NSString).deletingPathExtension }
        }
        return Set(names).filter { !$0.isEmpty && !$0.hasPrefix(".") }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }()
}

extension AudioCue {
    /// Shown next to the sound picker in Settings.
    var title: String {
        switch self {
        case .recordingStarted: "Recording starts"
        case .recordingStopped: "Recording stops"
        case .noteReady: "Note is ready"
        case .failed: "Something goes wrong"
        }
    }

    /// One of the sounds in /System/Library/Sounds.
    var defaultSound: String {
        switch self {
        case .recordingStarted: "Tink"
        case .recordingStopped: "Pop"
        case .noteReady: "Glass"
        case .failed: "Basso"
        }
    }
}
