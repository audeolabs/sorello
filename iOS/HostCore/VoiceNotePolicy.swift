import Foundation

/// Where the iPhone's power comes from, as UIKit's battery monitoring reports it. Read on the tick.
enum PowerSource: Equatable, Sendable {
    case connected
    case battery
    case unknown
}

/// Why a voice note ended (ARCHITECTURE.md, "Voice notes", Ending). Content-free.
enum NoteEndReason: String, Equatable, Sendable {
    /// The user's stop.
    case stopped
    /// The cap.
    case reachedLimit
    /// The session ended as the user's End.
    case sessionEnded
    /// A call or another app took the microphone.
    case interrupted
    /// The capture failed and could not be recovered, or could not start.
    case captureFailed
    case microphonePermissionDenied
    /// The model could not be had: the build has none, or its preparation failed.
    case modelUnavailable
    case modelFailed
    /// The stream failed. What was written stays.
    case transcriptionFailed
    /// A settled piece could not be written.
    case storageFailed
    /// iOS ended the background time the last piece was finishing in.
    case backgroundTimeExpired
    /// The note the run went into was deleted.
    case noteGone
}

/// Why a start needs the app in front (ARCHITECTURE.md, "Voice notes", Starting).
enum NoteNeedsApp: Equatable, Sendable {
    /// No vault yet: the app makes one.
    case noVault
    /// Microphone permission is not granted: the prompt, or "Microphone off", needs the app.
    case microphone
    /// The lock latch is set and the call does not prove the unlock.
    case locked
    /// Capture cannot start from here: the app is not in front, or iOS refused a background start.
    case foreground
    /// The background start's Live Activity does not show.
    case liveActivity
}

/// What a start, or the control's toggle, did (ARCHITECTURE.md, "Voice notes", Starting).
enum NoteStartOutcome: Equatable, Sendable {
    /// The note prepares or records, in a session that is starting or active.
    case started
    /// Capture started in the background for it: the caller shows the session's Live Activity now, or calls
    /// `noteNeedsForeground`.
    case startedInBackground
    /// The control's toggle stopped the note that prepared or recorded.
    case stopped
    /// A note prepares, records or saves: nothing changed.
    case busy
    case needsApp(NoteNeedsApp)
    /// It could not start, for this reason; or it started and ended during the call.
    case failed(NoteEndReason)
}

/// What the core reports of a note, without its text (ARCHITECTURE.md, "Voice notes").
enum NoteChange: Equatable, Sendable {
    /// A note started preparing; its run goes into this note.
    case started(noteID: UUID)
    /// A settled piece was written into this note.
    case wrote(noteID: UUID)
    /// The note ended. Everything written stays.
    case ended(noteID: UUID, reason: NoteEndReason)
}

/// Content-free measurements of the current or last note, held in memory only, for Diagnostics
/// (ARCHITECTURE.md, "Voice notes", Diagnostics).
struct NoteMeasurement: Equatable, Sendable {
    /// Reports the stream delivered: one per chunk transcribed, and the last.
    var piecesTranscribed = 0
    /// Of those, the ones that arrived while iOS reported protected data unavailable: the iPhone was locked.
    var piecesWhileLocked = 0
    /// Of those, the ones that arrived with the app in the background.
    var piecesInBackground = 0
    /// Nil while the note goes on.
    var ending: NoteEndReason?
    var hint: ComputeFailureHint?
}

/// The voice note's pure rules: its cap, and what a session's end means for it (ARCHITECTURE.md, "Voice notes").
enum VoiceNotePolicy {
    /// On battery a note ends this long after its start or the last unplug, whichever is later.
    static let batteryDuration: TimeInterval = 60 * 60
    /// ActivityKit ends a Live Activity this long after it starts ("Displaying live data with Live Activities":
    /// "A Live Activity can be active for up to eight hours").
    static let activityLifetime: TimeInterval = 8 * 60 * 60
    /// A note stops this long before the activity's lifetime runs out, so the activity is still there to show that
    /// the note was saved, and to carry the cap's alert.
    static let activityMargin: TimeInterval = 5 * 60
    /// How long after the activity started the cap stops a note.
    static let activityBound = activityLifetime - activityMargin

    /// When the cap ends the note under `power`. The session's Live Activity bounds every note, so nothing records
    /// without a visible state: `activityBound` counts from `activityStartedAt`, or from the note's start when no
    /// activity shows. On battery, or with the power state unknown, the battery limit counts from the later of the
    /// start and the last unplug.
    static func endsAt(startedAt: Date, lastUnpluggedAt: Date?, power: PowerSource, activityStartedAt: Date?) -> Date {
        let activityEnd = (activityStartedAt ?? startedAt) + activityBound
        guard power != .connected else { return activityEnd }
        return min(activityEnd, batteryStart(startedAt, lastUnpluggedAt) + batteryDuration)
    }

    /// Whether the cap has ended the note. Fails closed: a clock that jumped back past the tolerance ends it.
    static func hasReachedCap(startedAt: Date, lastUnpluggedAt: Date?, power: PowerSource, activityStartedAt: Date?,
                              now: Date) -> Bool {
        if !DictationProtocol.isFresh(activityStartedAt ?? startedAt, ttl: activityBound, now: now) { return true }
        if !DictationProtocol.isFresh(startedAt, ttl: .infinity, now: now) { return true }
        guard power != .connected else { return false }
        return !DictationProtocol.isFresh(batteryStart(startedAt, lastUnpluggedAt), ttl: batteryDuration, now: now)
    }

    /// The deadline `status.json` publishes: when the cap ends the note on battery, and none with power connected,
    /// where nothing counts down.
    static func publishedEnd(startedAt: Date, lastUnpluggedAt: Date?, power: PowerSource, activityStartedAt: Date?) -> Date? {
        guard power != .connected else { return nil }
        return endsAt(startedAt: startedAt, lastUnpluggedAt: lastUnpluggedAt, power: power,
                      activityStartedAt: activityStartedAt)
    }

    /// The note's reason when the session ends under it.
    static func endReason(after reason: SessionEndReason) -> NoteEndReason {
        switch reason {
        case .user, .idleExpired, .deviceLocked: return .sessionEnded
        case .interrupted: return .interrupted
        case .engineFailed, .mediaServicesReset: return .captureFailed
        case .startFailed(.microphonePermissionDenied): return .microphonePermissionDenied
        case .startFailed: return .captureFailed
        }
    }

    /// The reason a preparation that failed leaves, as admission's codes.
    static func preparationFailure(model: HostStatus.Model) -> NoteEndReason? {
        switch HostSessionPolicy.admissionFailure(model: model) {
        case .modelUnavailable?: return .modelUnavailable
        case .some: return .modelFailed
        case nil: return nil
        }
    }

    private static func batteryStart(_ startedAt: Date, _ lastUnpluggedAt: Date?) -> Date {
        max(startedAt, lastUnpluggedAt ?? startedAt)
    }
}
