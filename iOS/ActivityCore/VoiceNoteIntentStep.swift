import Foundation

/// What a voice note's intent does once the host has acted (ARCHITECTURE.md, "Voice Note control"): the "Voice Note"
/// control's toggle and the Live Activity's Note and Stop. Compiled into the app, which decides it, the extension,
/// whose intents name it, and the host tests. Pure.
enum VoiceNoteIntentStep: Equatable, Sendable {
    /// The note started, stopped, or was already saving.
    case done
    /// The start needs the app, for this reason.
    case needsApp(Need)
    /// The start failed.
    case failed(Failure)
    /// No host to act: the extension, or a misconfigured build.
    case unavailable

    enum Need: Equatable, Sendable {
        case noVault, microphone, locked, foreground, liveActivity
    }

    enum Failure: Equatable, Sendable {
        case model, storage, other
    }

    /// The one sentence the intent fails with; nil when it succeeds.
    var message: String? {
        switch self {
        case .done: return nil
        case .needsApp(.noVault): return "Open Sorello to set up notes first."
        case .needsApp(.microphone): return "Open Sorello to allow the microphone."
        case .needsApp(.locked): return "Unlock iPhone to start a note."
        case .needsApp(.liveActivity): return "Turn on Live Activities for Sorello, or open it to record."
        case .needsApp(.foreground): return "Open Sorello to start the note."
        case .failed(.model): return "The speech model could not load."
        case .failed(.storage): return "The note could not be saved."
        case .failed(.other): return "The note could not start."
        case .unavailable: return "Open Sorello to start a note."
        }
    }
}
