import Foundation

/// The host state the session's Live Activity follows (ARCHITECTURE.md, "Live Activity"). Content-free.
struct SessionActivityInput: Equatable, Sendable {
    var sessionID: UUID?
    var session: HostStatus.Session
    var sessionExpiresAt: Date?
    var dictation: DictationStatus?
    var model: HostStatus.Model
    /// The voice note preparing, recording or saving (`HostSessionCore.voiceNote`).
    var voiceNote: VoiceNoteStatus? = nil
    /// How the last voice note ended (`NoteMeasurement.ending`); nil while it goes on.
    var lastNoteEnding: NoteEndReason? = nil
    /// A vault exists, so the activity offers to start a note.
    var noteVault = false
}

extension HostSessionCore {
    /// What the session's Live Activity follows now; `noteVault`: a vault exists (the caller reads it rarely).
    func activityInput(noteVault: Bool) -> SessionActivityInput {
        SessionActivityInput(sessionID: sessionID, session: session, sessionExpiresAt: sessionExpiresAt, dictation: current,
                             model: transcriber.modelState, voiceNote: voiceNote, lastNoteEnding: lastNote?.ending,
                             noteVault: noteVault)
    }
}

/// How a voice note ended, and when the driver saw it end: the beat after it (ARCHITECTURE.md, "Live Activity").
struct SessionActivityNoteEnd: Equatable, Sendable {
    var reason: NoteEndReason
    var at: Date
}

/// The one alert the activity ever makes (ARCHITECTURE.md, "Live Activity", Alert). Content-free.
enum SessionActivityAlert: Equatable, Sendable {
    /// The cap ended a voice note, which was saved.
    case noteReachedLimit

    var title: String { "Note saved" }
    var body: String { "It reached its time limit." }
}

/// One content update: the state and when the system should treat it as out of date.
struct SessionActivityContent: Equatable, Sendable {
    var state: SessionActivityState
    var staleDate: Date
}

/// ActivityKit, behind the thinnest seam: `LiveActivityBackend` (App) in the app, a fake in the tests.
@MainActor
protocol SessionActivityBackend: AnyObject {
    /// The user's Live Activities switch for the app.
    var areActivitiesEnabled: Bool { get }
    /// Ends, at once, every activity an earlier run left behind.
    func endLeftovers()
    /// Requests the activity; false when the system refuses.
    func start(_ content: SessionActivityContent) -> Bool
    /// Updates the activity this run started, without an alert unless `alert` says one.
    func update(_ content: SessionActivityContent, alert: SessionActivityAlert?)
    /// Ends the activity this run started and removes it at once.
    func end()
    /// Waits until ActivityKit has answered every call made so far; whether the activity this run started exists.
    func settle() async -> Bool
    /// Hears that the activity this run started is gone other than by `end`: the user removed it, or the system
    /// ended it.
    var onRemoved: (@MainActor () -> Void)? { get set }
}

/// Which state the activity shows for the host's state, and when that state goes stale. Pure.
enum SessionActivityPolicy {
    /// How long after the session would have ended, or a recording been cut off, a killed app's activity turns stale.
    static let staleGrace: TimeInterval = 30
    /// When a wait (transcribing, preparing) or a ready state without an expiry turns stale.
    static let waitStaleInterval: TimeInterval = 300
    /// A wait shows at least this long before it gives way to anything but a recording, so a fast transcription reads
    /// as a beat rather than a flicker.
    static let minimumWaitDisplay: TimeInterval = 0.5
    /// A voice note has no bound a killed app's activity could go stale at: each of its states goes stale this long
    /// after it was sent, and the driver sends it again every `noteStaleRefresh` while the note goes on.
    static let noteStaleInterval: TimeInterval = 4 * 60
    static let noteStaleRefresh: TimeInterval = 2 * 60
    /// A note's countdown turns ember this long before its cap.
    static let noteWarning: TimeInterval = 5 * 60
    /// "Note saved" shows this long after a stop, and `limitSavedDisplay` after the cap ended the note.
    static let noteSavedDisplay: TimeInterval = 3
    static let limitSavedDisplay: TimeInterval = 30

    /// Nil: no activity. Only an active session shows: a starting one has no capture yet and may still fail.
    /// `noteEnd`: the last note's end as the driver saw it, for the beat after it.
    static func state(for input: SessionActivityInput, noteEnd: SessionActivityNoteEnd? = nil,
                      now: Date) -> SessionActivityState? {
        guard input.session == .active else { return nil }
        let note = input.voiceNote
        if let note, note.phase != .saving {
            return SessionActivityState(phase: note.phase == .recording ? .noteRecording : .notePreparing,
                                        endsAt: note.endsAt, since: note.phase == .recording ? note.startedAt : nil,
                                        onPower: note.onPower,
                                        lastMinutes: note.endsAt.map { $0.timeIntervalSince(now) <= noteWarning } ?? false)
        }
        switch input.dictation?.phase {
        case .starting?, .recording?:
            return SessionActivityState(phase: .recording, since: input.dictation?.startedAt)
        default:
            break
        }
        if let note, note.phase == .saving {
            return SessionActivityState(phase: .noteSaving, onPower: note.onPower)
        }
        if input.dictation?.phase == .transcribing {
            return SessionActivityState(phase: input.model == .preparing ? .preparing : .transcribing)
        }
        if let noteEnd, let display = savedDisplay(after: noteEnd.reason), now < noteEnd.at + display {
            return SessionActivityState(phase: .noteSaved, atLimit: noteEnd.reason == .reachedLimit)
        }
        return SessionActivityState(phase: .ready, endsAt: input.sessionExpiresAt, offersNote: input.noteVault)
    }

    /// How long "Note saved" shows after a note ended this way; nil for an ending that saved nothing the user asked
    /// for (a failure, the session's end).
    static func savedDisplay(after reason: NoteEndReason) -> TimeInterval? {
        switch reason {
        case .stopped: return noteSavedDisplay
        case .reachedLimit: return limitSavedDisplay
        default: return nil
        }
    }

    static func staleDate(for state: SessionActivityState, now: Date) -> Date {
        switch state.phase {
        case .ready:
            return state.endsAt.map { $0 + staleGrace } ?? now + waitStaleInterval
        case .recording:
            return (state.since ?? now) + DictationProtocol.maxDictationDuration + staleGrace
        case .transcribing, .preparing:
            return now + waitStaleInterval
        case .notePreparing, .noteRecording, .noteSaving, .noteSaved:
            let refreshed = now + noteStaleInterval
            return state.endsAt.map { min(refreshed, $0 + staleGrace) } ?? refreshed
        }
    }

    static func isWait(_ phase: SessionActivityState.Phase) -> Bool { phase == .transcribing || phase == .preparing }

    /// What a held wait gives way to at once: a recording, or a note in progress.
    static func isCapture(_ state: SessionActivityState) -> Bool { state.phase == .recording || state.isNoteInProgress }

    /// The driver sends the same state again with a new stale date: a note preparing, recording or saving.
    static func needsStaleRefresh(_ phase: SessionActivityState.Phase) -> Bool {
        phase == .notePreparing || phase == .noteRecording || phase == .noteSaving
    }
}

/// Starts, updates and ends the session's Live Activity (ARCHITECTURE.md, "Live Activity"). The controller calls
/// `sync` after every status change and on its tick; the driver touches the backend only when what the activity
/// shows changes: never for levels or heartbeats.
@MainActor
final class SessionActivityDriver {
    private let backend: SessionActivityBackend
    private var launched = false
    /// The session whose activity this run shows, and what it shows.
    private var shown: (sessionID: UUID?, content: SessionActivityContent, at: Date)?
    /// A session whose start the system refused: not asked again.
    private var refusedSessionID: UUID?
    /// Whether the last sync saw a voice note, and how the last one ended, as the driver saw it: the beat after it.
    private var sawNote = false
    private var noteEnd: SessionActivityNoteEnd?
    /// The beat after the cap has alerted.
    private var alerted = false
    /// When the activity the driver shows was started, nil while it shows none. ActivityKit's lifetime counts from
    /// here; a voice note's cap follows it (ARCHITECTURE.md, "Voice notes", Cap).
    private(set) var startedAt: Date?

    /// Hears that the activity the driver showed was removed by the user or the system (ARCHITECTURE.md, "Live
    /// Activity", Removed).
    var onRemoved: (@MainActor () -> Void)?

    init(backend: SessionActivityBackend) {
        self.backend = backend
        backend.onRemoved = { [weak self] in self?.activityRemoved() }
    }

    /// The activity is gone other than by the driver's own end: it shows none, until a sync that may start one
    /// shows the session again.
    private func activityRemoved() {
        guard shown != nil else { return }
        shown = nil
        startedAt = nil
        onRemoved?()
    }

    /// Once, at launch, before any session can start.
    func launch() {
        guard !launched else { return }
        launched = true
        backend.endLeftovers()
    }

    /// `mayStart`: ActivityKit would start an activity now, because the app is active or a control's intent is
    /// running.
    func sync(_ input: SessionActivityInput, mayStart: Bool, now: Date) {
        observeNote(input, now: now)
        let desired = SessionActivityPolicy.state(for: input, noteEnd: noteEnd, now: now)
        if let current = shown, desired == nil || current.sessionID != input.sessionID {
            backend.end()
            shown = nil
            startedAt = nil
        }
        guard let desired else { return }
        if let current = shown {
            if current.content.state == desired {
                // A note's state is sent again before it goes stale (ARCHITECTURE.md, "Live Activity", Stale date).
                guard SessionActivityPolicy.needsStaleRefresh(desired.phase),
                      HostSessionPolicy.isDue(last: current.at, interval: SessionActivityPolicy.noteStaleRefresh, now: now)
                else { return }
            } else if SessionActivityPolicy.isWait(current.content.state.phase), !SessionActivityPolicy.isCapture(desired),
                      now < current.at + SessionActivityPolicy.minimumWaitDisplay {
                return   // held; a later tick applies it
            }
            let content = SessionActivityContent(state: desired, staleDate: SessionActivityPolicy.staleDate(for: desired, now: now))
            backend.update(content, alert: alert(for: desired))
            shown = (input.sessionID, content, now)
            return
        }
        // ActivityKit starts an activity only in the foreground or in a Live Activity intent. Switched off or
        // refused: nothing, and no prompt.
        guard mayStart, refusedSessionID != input.sessionID, backend.areActivitiesEnabled else { return }
        let content = SessionActivityContent(state: desired, staleDate: SessionActivityPolicy.staleDate(for: desired, now: now))
        if backend.start(content) {
            shown = (input.sessionID, content, now)
            startedAt = now
        } else {
            refusedSessionID = input.sessionID
        }
    }

    /// A voice note's status that goes while its ending is known starts the beat after it.
    private func observeNote(_ input: SessionActivityInput, now: Date) {
        if input.voiceNote != nil {
            noteEnd = nil
        } else if sawNote, let reason = input.lastNoteEnding {
            noteEnd = SessionActivityNoteEnd(reason: reason, at: now)
            alerted = false
        }
        sawNote = input.voiceNote != nil
    }

    /// The first update that shows the cap's "Note saved" alerts; no other.
    private func alert(for state: SessionActivityState) -> SessionActivityAlert? {
        guard state.phase == .noteSaved, state.atLimit == true, !alerted else { return nil }
        alerted = true
        return .noteReachedLimit
    }

    /// Whether the activity the driver shows exists once ActivityKit has answered (ARCHITECTURE.md, "Live
    /// Activity", Settle). A request refused once queued counts as refused: forgotten, and not asked again for
    /// that session.
    func settle() async -> Bool {
        guard let before = shown else { return false }
        let exists = await backend.settle()
        guard let current = shown, current.sessionID == before.sessionID else { return false }
        if !exists {
            refusedSessionID = current.sessionID
            shown = nil
            startedAt = nil
        }
        return exists
    }
}
