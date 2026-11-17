import Foundation

/// The host side of the voice note's intents (ARCHITECTURE.md, "Voice Note control"; "Live Activity", Buttons): the
/// "Voice Note" control's toggle and the Live Activity's Note and Stop. `HostSessionController` (App) runs them;
/// `showActivity` lets the session's Live Activity start now (`mayStart`) and reports, once ActivityKit has answered,
/// whether it shows.
@MainActor
enum VoiceNoteIntentFlow {
    /// The "Voice Note" control: stops the note in progress, or starts one in a new note, and shows the session's Live
    /// Activity for it. A background start whose activity does not show ends at once.
    static func toggleFromControl(_ core: HostSessionCore, showActivity: () async -> Bool) async -> VoiceNoteIntentStep {
        let outcome = core.controlToggleNote(.newNote)
        switch outcome {
        case .started:
            // In front, the app's own screen shows the note: a refusal leaves it recording. Joining a session from
            // the background, the note needs the activity as a background start does: without it the note stops, and
            // the session, which was there before, goes on.
            if await showActivity() || core.isInFront { return .done }
            core.stopNote()
            return .needsApp(.liveActivity)
        case .startedInBackground:
            let sessionID = core.sessionID
            if await showActivity() { return .done }
            // Ended meanwhile for another reason: nothing is left to end.
            guard core.session == .active, core.sessionID == sessionID else { return .done }
            return step(for: core.noteNeedsForeground())
        default:
            return step(for: outcome)
        }
    }

    /// The Live Activity's Note, which iOS runs after authenticating the user: always a new note.
    static func startFromActivity(_ core: HostSessionCore) -> VoiceNoteIntentStep {
        step(for: core.activityStartNote(.newNote))
    }

    /// The Live Activity's Stop: needs nothing, and never fails.
    static func stopFromActivity(_ core: HostSessionCore) -> VoiceNoteIntentStep {
        core.stopNote()
        return .done
    }

    /// What an intent reports for a start's outcome.
    nonisolated static func step(for outcome: NoteStartOutcome) -> VoiceNoteIntentStep {
        switch outcome {
        case .started, .startedInBackground, .stopped, .busy:
            return .done
        case .needsApp(let need):
            switch need {
            case .noVault: return .needsApp(.noVault)
            case .microphone: return .needsApp(.microphone)
            case .locked: return .needsApp(.locked)
            case .foreground: return .needsApp(.foreground)
            case .liveActivity: return .needsApp(.liveActivity)
            }
        case .failed(let reason):
            switch reason {
            case .microphonePermissionDenied: return .needsApp(.microphone)
            case .captureFailed, .interrupted, .sessionEnded: return .needsApp(.foreground)
            case .modelUnavailable, .modelFailed: return .failed(.model)
            case .storageFailed, .noteGone: return .failed(.storage)
            case .stopped, .reachedLimit, .transcriptionFailed, .backgroundTimeExpired: return .failed(.other)
            }
        }
    }
}
