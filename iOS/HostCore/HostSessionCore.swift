import Foundation

/// Platform hooks, injected so the core stays Foundation-only and testable.
struct HostEnvironment {
    var now: @MainActor () -> Date
    /// The application state is not `.background` (active or inactive): capture may start, and a fresh
    /// record intent may be admitted without a session.
    var isForeground: @MainActor () -> Bool
    /// `UIApplication.isProtectedDataAvailable`. Read only on the willEnterForeground and didBecomeActive
    /// events, to lift the lock latch if the unlock notification was missed while suspended;
    /// never while polling, because during the will-become-unavailable window it still reads true.
    var isProtectedDataAvailable: @MainActor () -> Bool
    /// Begins a UIKit background task. `onExpiration` runs on main when time runs out; the returned
    /// closure ends the task, and the core calls it exactly once.
    var beginBackgroundTask: @MainActor (_ onExpiration: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    /// The shared text rules (`DictationRules.process`, from `TextRules`), which only the app links.
    var formatTranscript: @MainActor (_ text: String, _ pressEnterEnabled: Bool, _ spokenDelimitersEnabled: Bool,
                                      _ spokenNumbersEnabled: Bool) -> (text: String, pressEnter: Bool)
    /// Where the power comes from (UIKit's battery monitoring), for a voice note's cap. Read on the tick.
    var powerState: @MainActor () -> PowerSource = { .unknown }
}

/// What a press of the session control did (ARCHITECTURE.md, "Session control").
enum SessionControlOutcome: Equatable, Sendable {
    /// A starting or active session ended, as the user's End.
    case ended
    /// The app is in front: the session starts as `userStartSession` starts it.
    case started
    /// Capture is running in the background. The caller shows the session's Live Activity now, or calls
    /// `controlNeedsForeground`.
    case startedInBackground
    /// The start needs the app in front; it is remembered for `HostSessionPolicy.controlForegroundWindow`.
    case needsForeground
}

/// The host side of the protocol: session lifecycle, idle expiry, reconciliation, run recovery,
/// watchdog, capture supervision, transcription and status publishing. `HostSessionController` (App)
/// drives it from timers, Darwin notifications and UIKit events and mirrors its state into SwiftUI.
///
/// Every asynchronous completion carries a `DictationTicket`, a session generation or an engine
/// generation and is dropped unless it is still current. Status is written after every change, and on
/// the cadence of `HostSessionPolicy` while live.
@MainActor
final class HostSessionCore {
    let hostRunID: UUID
    let store: SharedDictationStore
    let settings: SorelloSettings
    let buffer: DictationSampleBuffer
    let capture: HostCapture
    let transcriber: HostTranscriber
    private let notifier: DarwinNotifier?
    private let environment: HostEnvironment
    /// Begins a voice note's runs; nil when the notes directory is out of reach, and every note start then fails.
    private let noteRecorder: NoteRecorder?
    /// Words from corrections (ARCHITECTURE.md, "Custom dictionary"): what is kept of the newest dictation, and the
    /// added word taken and decided. Nil when the app has no dictionary to save into.
    let addedWords: AddedWordInbox?

    private(set) var isLaunched = false
    private(set) var session: HostStatus.Session = .inactive
    private(set) var sessionID: UUID?
    /// The most recent session-level error; cleared when a session starts.
    private(set) var sessionError: HostErrorCode?
    private(set) var slot: HostDictationSlot
    private(set) var knownRequestIDs = RecentRequestIDs()
    /// Idle expiry counts from here; nil while a dictation is in progress or no session is active.
    private(set) var idleSince: Date?
    private(set) var lastForegroundAt: Date?
    private(set) var hasBeenForeground = false
    /// The lock latch (ARCHITECTURE.md, "Device lock"), set by `deviceWillLock`. While set, no intent is
    /// admitted and no session, capture or dictation starts, even though iOS posts the lock notification
    /// before files become unreadable; a session already running goes on until idle expiry. Cleared by
    /// `deviceDidUnlock`, by the `appWillEnterForeground` / `appDidBecomeActive` events with protected
    /// data available (a suspended app can miss the unlock notification), and by a record intent issued
    /// after `lockWriteWindow` (`HostSessionPolicy.intentProvesUnlock`); never by polling or a derived state.
    private(set) var isLocked = false
    /// When the latch was last set.
    private var lockedAt: Date?

    private var sessionGeneration: UInt64 = 0
    /// A session start waiting for the foreground (the permission prompt was answered elsewhere).
    private var pendingStart: UInt64?
    /// A session control press whose start needs the app in front, and when it was made.
    private var controlStartRequestedAt: Date?
    private var transcription: Transcription?
    private var needsPublish = false
    private var lastStatusAt: Date?
    private var lastPurgeAt: Date?
    private var lastReconcileAt: Date?
    /// Capture supervision: a reported or observed failure waits out `captureStallGrace` here.
    private var captureFailingSince: Date?
    /// When the current engine started, the baseline for starvation before its first buffer.
    private var captureStartedAt: Date?
    private var recoveriesWithoutInput = 0
    /// Sample growth of the recording, to detect a recording that stopped receiving audio.
    private var recordingProgress: (generation: UInt64, duration: TimeInterval, since: Date)?
    /// A memory warning not yet acted on: the model is released once nothing uses it.
    private var pendingModelRelease = false
    /// A finished recording waiting for its tail: frames captured before the finish but not yet
    /// delivered. It is drained when the capture reports the tail complete, or after `tailTimeout`.
    private var closing: (ticket: DictationTicket, since: Date)?

    /// The voice note (ARCHITECTURE.md, "Voice notes"): preparing, recording, closing or saving; nil when none.
    private var note: ActiveNote?
    private var noteGeneration: UInt64 = 0
    /// What happened to notes since the last status write, delivered after it.
    private var noteChanges: [NoteChange] = []
    /// Content-free measurements of the current or last note, in memory only.
    private(set) var lastNote: NoteMeasurement?
    /// When the session's Live Activity started, nil while none shows: the controller sets it after every sync. A
    /// note's cap counts the activity's lifetime from here.
    var sessionActivityStartedAt: Date?

    /// Runs after every status write, for the UI.
    var onChange: (@MainActor () -> Void)?
    /// Sees every status written, in order.
    var onPublish: (@MainActor (HostStatus) -> Void)?
    /// Hears, after the status write, that a note started, that a piece was written into it, and that it ended.
    var onNoteChange: (@MainActor (NoteChange) -> Void)?
    /// Hears a note's provisional tail as each report arrives. Unset, the tail is dropped; the core keeps no note text.
    var onNoteProvisional: (@MainActor (_ noteID: UUID, _ provisional: String) -> Void)?

    private struct Transcription {
        let ticket: DictationTicket
        let task: Task<Void, Never>
        let endBackgroundTask: OnceAction
    }

    init(hostRunID: UUID = UUID(), store: SharedDictationStore, settings: SorelloSettings,
         buffer: DictationSampleBuffer, capture: HostCapture, transcriber: HostTranscriber,
         notifier: DarwinNotifier?, environment: HostEnvironment, noteRecorder: NoteRecorder? = nil,
         addedWords: AddedWordInbox? = nil) {
        self.hostRunID = hostRunID
        self.noteRecorder = noteRecorder
        self.addedWords = addedWords
        self.store = store
        self.settings = settings
        self.buffer = buffer
        self.capture = capture
        self.transcriber = transcriber
        self.notifier = notifier
        self.environment = environment
        slot = HostDictationSlot(hostRunID: hostRunID)
        addedWords?.onOutcome = { [weak self] in self?.addedWordDecided() }
    }

    // MARK: State for the UI

    var current: DictationStatus? { slot.current }
    var isDictationInProgress: Bool { slot.isInProgress }
    var level: Float { slot.phase == .recording ? buffer.level : 0 }
    var sessionExpiresAt: Date? {
        HostSessionPolicy.sessionExpiresAt(session: session, idleSince: idleSince, duration: settings.sessionDuration)
    }
    /// The app is in front (not in the background), where its own screens show a voice note.
    var isInFront: Bool { environment.isForeground() }
    /// The note that prepares, records or saves, as `status.json` publishes it.
    var voiceNote: VoiceNoteStatus? { note.map(noteStatus) }
    /// Which note it writes into.
    var voiceNoteID: UUID? { note?.writer.noteID }
    /// A note prepares or records: idle expiry waits, and keyboard requests are refused.
    private var isNoteInProgress: Bool { note?.isInProgress == true }

    // MARK: Inputs

    /// Run recovery, then the launch reconciliation. Call once, after UIKit has finished launching.
    func launch() {
        guard !isLaunched else { return }
        isLaunched = true
        let now = environment.now()
        // Before this run writes anything: a staging file left by a crash mid-write may hold a transcript.
        store.purgeStagingFiles(olderThan: 0, now: now)
        let recovery = HostRunRecovery(previous: store.readStatus(), hostRunID: hostRunID, now: now)
        slot = HostDictationSlot(hostRunID: hostRunID, recovered: recovery.current)
        for id in recovery.knownRequestIDs { knownRequestIDs.insert(id) }
        let run = hostRunID
        store.purgeResults { _, read in HostRunRecovery.isFromAnotherRun(read, hostRunID: run) }
        store.purgeExpiredResults(now: now)
        addedWords?.take()
        lastPurgeAt = now
        // The previous run's interrupted request is published before anything is reconciled.
        needsPublish = true
        flush(now)
        noteForeground(now)
        reconcilePass(.launch, now)
        flush(now)
    }

    /// A URL open is passed as `.urlOpen`: only a hint, acted on once the app is actually in front.
    func reconcile(_ trigger: ReconcileTrigger) {
        guard isLaunched else { return }
        let now = environment.now()
        noteForeground(now)
        reconcilePass(trigger, now)
        flush(now)
    }

    /// The controller's timer, every `HostSessionPolicy.tickInterval`.
    func tick() {
        guard isLaunched else { return }
        let now = environment.now()
        let foreground = noteForeground(now)
        superviseDictation(now, foreground: foreground)
        superviseCapture(now)
        // A deferred start nobody is waiting for any more (its request timed out) is abandoned.
        if let closing, HostSessionPolicy.isDue(last: closing.since, interval: HostSessionPolicy.tailTimeout, now: now) {
            drainClosing(now)   // the tail never arrived (a stalled engine): transcribe what did
        }
        superviseNote(now)
        addedWords?.expire()
        if pendingStart != nil, !slot.isInProgress { endSession(.startFailed(.audioSessionFailed), now) }
        if let requested = controlStartRequestedAt,
           !HostSessionPolicy.isControlStartFresh(requestedAt: requested, now: now) {
            controlStartRequestedAt = nil
        }
        endSessionIfIdleExpired(now)
        releaseModelIfPending()
        let live = session != .inactive || foreground || slot.isInProgress || note != nil
        if session != .inactive || foreground,
           HostSessionPolicy.isDue(last: lastReconcileAt, interval: HostSessionPolicy.reconcileInterval, now: now) {
            reconcilePass(.poll, now)
        }
        if live, HostSessionPolicy.isDue(last: lastPurgeAt, interval: DictationProtocol.heartbeatInterval, now: now) {
            store.purgeExpiredResults(now: now)
            addedWords?.take()
            lastPurgeAt = now
        }
        if live, HostSessionPolicy.isDue(last: lastStatusAt, interval: HostSessionPolicy.statusInterval(for: slot.current),
                                         now: now) {
            needsPublish = true
        }
        flush(now)
    }

    /// Scene or application state changed. Arriving in the foreground re-reads the intent and
    /// reconciles, with freshness judged at that moment: this is what admits a request after a URL open.
    func foregroundChanged() {
        guard isLaunched else { return }
        let now = environment.now()
        if noteForeground(now) {
            if let pending = pendingStart { continueSessionStart(pending, now) }
            // The session control's start that needed the app (ARCHITECTURE.md, "Session control", Foreground).
            if let requested = controlStartRequestedAt {
                controlStartRequestedAt = nil
                if session == .inactive, !isLocked, HostSessionPolicy.isControlStartFresh(requestedAt: requested, now: now) {
                    transcriber.prepare()
                    startSession(now)
                }
            }
            // A choice made while the app could not apply it takes effect now that it is in front.
            if session == .active, capture.needsReconfiguration { reconfigureCapture(now) }
            reconcilePass(.activation, now)
            addedWords?.take()
        }
        needsPublish = true
        flush(now)
    }

    /// `willEnterForegroundNotification`. The application state may still read background here, so the
    /// event itself (with protected data available) lifts the lock latch, before anything reconciles.
    func appWillEnterForeground() {
        unlatchIfProtectedDataAvailable()
        foregroundChanged()
    }

    /// `didBecomeActiveNotification`: as `appWillEnterForeground`.
    func appDidBecomeActive() {
        unlatchIfProtectedDataAvailable()
        foregroundChanged()
    }

    private func unlatchIfProtectedDataAvailable() {
        if isLocked, environment.isProtectedDataAvailable() { isLocked = false }
    }

    func userStartSession() {
        guard isLaunched, session == .inactive, !isLocked else { return }
        let now = environment.now()
        guard noteForeground(now) else { return }
        transcriber.prepare()   // in parallel with audio startup, as admission does
        startSession(now)
        flush(now)
    }

    func userEndSession() {
        let now = environment.now()
        endSession(.user, now)
        flush(now)
    }

    // MARK: Session control (ARCHITECTURE.md, "Session control")

    /// A press of the session control, which iOS runs as an `AudioRecordingIntent` after authenticating the user:
    /// ends a starting or active session, or starts one, in the background when the app is there.
    func controlToggleSession() -> SessionControlOutcome {
        let now = environment.now()
        defer { flush(now) }
        guard isLaunched else { return requestForegroundStart(now) }
        if session != .inactive {
            endSession(.user, now)
            return .ended
        }
        liftLatchIfIntentProvesUnlock(now)
        if noteForeground(now), !isLocked {
            transcriber.prepare()
            startSession(now)
            return .started
        }
        // The prompt and "Microphone off" need the app, and nothing starts while locked.
        guard !isLocked, capture.permission == .granted else { return requestForegroundStart(now) }
        transcriber.prepare()
        startSession(now, inBackground: true)
        // A capture start iOS refused ended the session as a failed start.
        return session == .active ? .startedInBackground : requestForegroundStart(now)
    }

    /// The background start's Live Activity does not show: the session ends at once, as the user's End, and the
    /// start waits for the foreground instead, or starts again at once when the app arrived in front meanwhile (its
    /// activation events came before this). Returns `.started` or `.needsForeground`.
    @discardableResult
    func controlNeedsForeground() -> SessionControlOutcome {
        let now = environment.now()
        defer { flush(now) }
        endSession(.user, now)
        if noteForeground(now), !isLocked {
            transcriber.prepare()
            startSession(now)
            return .started
        }
        return requestForegroundStart(now)
    }

    private func requestForegroundStart(_ now: Date) -> SessionControlOutcome {
        controlStartRequestedAt = now
        return .needsForeground
    }

    /// iOS authenticated the user before running an intent; a suspended app may have missed the unlock
    /// (`HostSessionPolicy.controlProvesUnlock`).
    private func liftLatchIfIntentProvesUnlock(_ now: Date) {
        if isLocked, HostSessionPolicy.controlProvesUnlock(now: now, lockedAt: lockedAt,
                                                           isProtectedDataAvailable: environment.isProtectedDataAvailable()) {
            isLocked = false
        }
    }

    // MARK: Voice notes (ARCHITECTURE.md, "Voice notes")

    /// The app's own Record: the app in front and the latch clear. Starts a session as `userStartSession` does when
    /// there is none.
    func userStartNote(_ target: NoteRunTarget) -> NoteStartOutcome {
        let now = environment.now()
        defer { flush(now) }
        guard isLaunched, noteForeground(now) else { return .needsApp(.foreground) }
        guard note == nil else { return .busy }
        guard !isLocked else { return .needsApp(.locked) }
        return startNoteInFront(target, now)
    }

    /// The Live Activity's start, which iOS runs after authenticating the user. In the background it needs an active
    /// session, since it may not start capture.
    func activityStartNote(_ target: NoteRunTarget) -> NoteStartOutcome {
        let now = environment.now()
        defer { flush(now) }
        guard isLaunched else { return .needsApp(.foreground) }
        guard note == nil else { return .busy }
        liftLatchIfIntentProvesUnlock(now)
        guard !isLocked else { return .needsApp(.locked) }
        if noteForeground(now) { return startNoteInFront(target, now) }
        guard session == .active else { return .needsApp(.foreground) }
        return startNote(target, now)
    }

    /// The "Voice Note" control, which iOS runs as an `AudioRecordingIntent` after authenticating the user: stops the
    /// note that prepares or records, or starts one, starting a session as `controlToggleSession` does.
    func controlToggleNote(_ target: NoteRunTarget) -> NoteStartOutcome {
        let now = environment.now()
        defer { flush(now) }
        guard isLaunched else { return .needsApp(.foreground) }
        if isNoteInProgress {
            stopNote(.stopped, now)
            return .stopped
        }
        guard note == nil else { return .busy }
        liftLatchIfIntentProvesUnlock(now)
        guard !isLocked else { return .needsApp(.locked) }
        if noteForeground(now) { return startNoteInFront(target, now) }
        if session != .inactive { return startNote(target, now) }
        // The prompt and "Microphone off" need the app.
        guard capture.permission == .granted else { return .needsApp(.microphone) }
        if let refused = beginNote(target, now) { return refused }
        let generation = noteGeneration
        startSession(now, inBackground: true)
        // A capture start iOS refused ended the session, and the note with it.
        guard session == .active else { return .needsApp(.foreground) }
        return noteOutcome(generation, .startedInBackground)
    }

    /// The background start's Live Activity does not show: the session ends as the user's End, as the session
    /// control's does, and the note with it, saving what it recorded.
    @discardableResult
    func noteNeedsForeground() -> NoteStartOutcome {
        let now = environment.now()
        defer { flush(now) }
        endSession(.user, now)
        return .needsApp(.liveActivity)
    }

    /// Stops the note that prepares or records. Never needs anything: not the app, not an unlock. Returns whether
    /// there was one.
    @discardableResult
    func stopNote() -> Bool {
        let now = environment.now()
        defer { flush(now) }
        guard isNoteInProgress else { return false }
        stopNote(.stopped, now)
        return true
    }

    private func startNoteInFront(_ target: NoteRunTarget, _ now: Date) -> NoteStartOutcome {
        if let refused = beginNote(target, now) { return refused }
        let generation = noteGeneration
        if session == .inactive { startSession(now) }
        return noteOutcome(generation, .started)
    }

    private func startNote(_ target: NoteRunTarget, _ now: Date) -> NoteStartOutcome {
        if let refused = beginNote(target, now) { return refused }
        return noteOutcome(noteGeneration, .started)
    }

    /// `started`, unless the note has already ended (a session start that failed): then why.
    private func noteOutcome(_ generation: UInt64, _ started: NoteStartOutcome) -> NoteStartOutcome {
        if note?.generation == generation { return started }
        return .failed(lastNote?.ending ?? .captureFailed)
    }

    /// Begins the run first, so nothing starts for a note that cannot be written, then the note, preparing. Nil when it
    /// started; otherwise why not.
    private func beginNote(_ target: NoteRunTarget, _ now: Date) -> NoteStartOutcome? {
        guard note == nil else { return .busy }
        guard let noteRecorder else { return .failed(.storageFailed) }
        let writer: NoteRunWriter
        do {
            writer = try noteRecorder.beginRun(target)
        } catch NoteError.noVault {
            return .needsApp(.noVault)
        } catch NoteError.noSuchNote {
            return .failed(.noteGone)
        } catch {
            return .failed(.storageFailed)
        }
        // A missing model, or a failed one still backing off, fails the note at once, as admission fails a request.
        transcriber.prepare()
        if let reason = VoiceNotePolicy.preparationFailure(model: transcriber.modelState) {
            writer.end()
            lastNote = NoteMeasurement(ending: reason, hint: noteFailureHint(reason, inBackground: !environment.isForeground()))
            return .failed(reason)
        }
        // A dictation that holds the capture gives way: one waiting for its tail is transcribed with what arrived, one
        // starting or recording is superseded. One transcribing goes on.
        if closing != nil { drainClosing(now) }
        if slot.phase == .starting || slot.phase == .recording { endInProgress(.cancelled(.superseded), now) }
        // A new recording: nothing is kept for an earlier dictation's correction.
        addedWords?.releaseAll()
        noteGeneration &+= 1
        note = ActiveNote(generation: noteGeneration, writer: writer, startedAt: now,
                          power: environment.powerState())
        lastNote = NoteMeasurement()
        idleSince = nil
        needsPublish = true
        noteChanges.append(.started(noteID: writer.noteID))
        advanceNote(now)
        return nil
    }

    /// A preparing note starts recording once the session is active and the model ready: the capture feeds a stream
    /// with progress and keeps no samples. A preparation that fails ends it.
    private func advanceNote(_ now: Date) {
        guard let current = note, current.phase == .preparing else { return }
        if let reason = VoiceNotePolicy.preparationFailure(model: transcriber.modelState) {
            endNote(reason, now)
            return
        }
        if transcriber.modelState == .notPrepared { transcriber.prepare() }
        guard session == .active, transcriber.modelState == .ready, let stream = transcriber.beginStream(.note) else { return }
        let recordingID = UUID()
        let generation = buffer.begin(requestID: recordingID, stream: stream, keepsSamples: false)
        capture.recordingBoundary()
        note?.phase = .recording
        note?.recordingID = recordingID
        note?.bufferGeneration = generation
        note?.stream = stream
        needsPublish = true
        consumeProgress(of: stream, current.generation)
    }

    private func consumeProgress(of stream: SpeechStream, _ generation: UInt64) {
        guard let feed = stream.progress else {
            endNote(.transcriptionFailed, environment.now())   // a stream that cannot report cannot write a note
            return
        }
        Task { [weak self] in
            for await report in feed { self?.noteReported(report, generation) }
            self?.noteFeedEnded(generation)
        }
    }

    /// Each report: the settled text is written at once and not kept; the provisional tail goes to the observer.
    private func noteReported(_ report: SpeechStreamProgress, _ generation: UInt64) {
        guard let current = note, current.generation == generation else { return }
        let now = environment.now()
        lastNote?.piecesTranscribed += 1
        // Only iOS's own answer counts as locked: in the lock's first seconds it still reads available.
        if !environment.isProtectedDataAvailable() { lastNote?.piecesWhileLocked += 1 }
        if !environment.isForeground() { lastNote?.piecesInBackground += 1 }
        needsPublish = true
        let noteID = current.writer.noteID
        if !report.settled.isEmpty {
            do {
                try current.writer.append(report.settled)
            } catch {
                endNote(.storageFailed, now)
                flush(now)
                return
            }
            noteChanges.append(.wrote(noteID: noteID))
        }
        flush(now)
        onNoteProvisional?(noteID, report.provisional)
    }

    /// The feed ends after the last report when the stream finishes, and early when it fails.
    private func noteFeedEnded(_ generation: UInt64) {
        guard note?.generation == generation else { return }
        let now = environment.now()
        note?.feedEnded = true
        if note?.phase == .saving {
            completeSavedNote(now)
        } else {
            endNote(.transcriptionFailed, now)   // the stream failed while it was fed
        }
        flush(now)
    }

    /// Stops a preparing note at once, and a recording one at the current capture time: its tail is drained as a
    /// dictation's is, then it saves. `reason` is what it ends with once saved.
    private func stopNote(_ reason: NoteEndReason, _ now: Date) {
        guard let current = note else { return }
        switch current.phase {
        case .preparing:
            endNote(reason, now)
        case .recording:
            guard let recordingID = current.recordingID, buffer.close(requestID: recordingID) else {
                endNote(.transcriptionFailed, now)
                return
            }
            note?.reason = reason
            note?.phase = .closing(since: now)
            // The microphone is no longer the note's: the idle countdown starts now.
            if session == .active, !slot.isInProgress { idleSince = now }
            needsPublish = true
            if !capture.isRunning { drainNote(now) }
        case .closing, .saving:
            break
        }
    }

    /// The tail has arrived, or will not: the stream finishes, inside a background task, and writes its last piece.
    private func drainNote(_ now: Date) {
        guard let current = note, case .closing = current.phase, let recordingID = current.recordingID else { return }
        guard let stream = buffer.finishRecording(requestID: recordingID)?.stream else {
            endNote(.transcriptionFailed, now)
            return
        }
        capture.recordingBoundary()
        note?.phase = .saving
        note?.recordingID = nil
        needsPublish = true
        let generation = current.generation
        let endBackgroundTask = OnceAction()
        endBackgroundTask.action = environment.beginBackgroundTask { [weak self] in
            self?.noteBackgroundTimeExpired(generation)
            endBackgroundTask.run()
        }
        note?.endBackgroundTask = endBackgroundTask
        Task { [weak self] in
            let succeeded: Bool
            do {
                _ = try await stream.finish()   // the pieces already reported; not kept
                succeeded = true
            } catch {
                succeeded = false
            }
            // The background task ends with the note, once its feed has delivered the last piece too.
            self?.noteFinished(generation, succeeded: succeeded)
        }
    }

    private func noteFinished(_ generation: UInt64, succeeded: Bool) {
        guard note?.generation == generation else { return }
        let now = environment.now()
        note?.finished = succeeded
        completeSavedNote(now)
        flush(now)
    }

    /// Ends a saving note once its stream has finished and its feed has delivered everything.
    private func completeSavedNote(_ now: Date) {
        guard let current = note, current.phase == .saving, current.feedEnded, let finished = current.finished else { return }
        endNote(finished ? current.reason : .transcriptionFailed, now)
    }

    private func noteBackgroundTimeExpired(_ generation: UInt64) {
        guard note?.generation == generation else { return }
        let now = environment.now()
        endNote(.backgroundTimeExpired, now)
        flush(now)
    }

    /// Ends the note: its stream is cancelled unless it finished, its run ends, and what was written stays.
    private func endNote(_ reason: NoteEndReason, _ now: Date) {
        guard let current = note else { return }
        note = nil
        if let recordingID = current.recordingID {
            buffer.cancel(requestID: recordingID)
            capture.recordingBoundary()
        }
        if current.finished == nil { current.stream?.cancel() }
        current.writer.end()
        current.endBackgroundTask?.run()
        lastNote?.ending = reason
        let inBackground = (lastNote?.piecesInBackground ?? 0) > 0 || !environment.isForeground()
        lastNote?.hint = noteFailureHint(reason, inBackground: inBackground)
        if current.isInProgress, session == .active, !slot.isInProgress { idleSince = now }
        needsPublish = true
        noteChanges.append(.ended(noteID: current.writer.noteID, reason: reason))
        releaseModelIfPending()
    }

    /// The background hint of a stream or a preparation that failed (ARCHITECTURE.md, "Transcription").
    private func noteFailureHint(_ reason: NoteEndReason, inBackground: Bool) -> ComputeFailureHint? {
        switch reason {
        case .modelFailed: return transcriber.failureHint(after: .modelFailed, inBackground: inBackground)
        case .transcriptionFailed: return transcriber.failureHint(after: .transcriptionFailed, inBackground: inBackground)
        default: return nil
        }
    }

    /// On the tick: the power state, the tail's timeout, the cap, and a preparing note's model.
    private func superviseNote(_ now: Date) {
        guard let current = note else { return }
        let power = environment.powerState()
        if power != current.power {
            if current.power == .connected { note?.lastUnpluggedAt = now }
            note?.power = power
            needsPublish = true
        }
        if case .closing(let since) = current.phase,
           HostSessionPolicy.isDue(last: since, interval: HostSessionPolicy.tailTimeout, now: now) {
            drainNote(now)   // the tail never arrived (a stalled engine): save what did
            return
        }
        guard let active = note, active.isInProgress else { return }
        if VoiceNotePolicy.hasReachedCap(startedAt: active.startedAt, lastUnpluggedAt: active.lastUnpluggedAt,
                                         power: active.power, activityStartedAt: sessionActivityStartedAt, now: now) {
            stopNote(.reachedLimit, now)
            return
        }
        advanceNote(now)
    }

    /// What the session's end means for the note: one preparing ends, one recording is saved with what arrived.
    private func noteSessionEnded(_ reason: SessionEndReason, _ now: Date) {
        guard let current = note else { return }
        let noteReason = VoiceNotePolicy.endReason(after: reason)
        switch current.phase {
        case .preparing:
            endNote(noteReason, now)
        case .recording:
            stopNote(noteReason, now)
            drainNote(now)
        case .closing:
            drainNote(now)
        case .saving:
            break
        }
    }

    private func noteStatus(_ current: ActiveNote) -> VoiceNoteStatus {
        let phase: VoiceNoteStatus.Phase
        switch current.phase {
        case .preparing: phase = .preparing
        case .recording: phase = .recording
        case .closing, .saving: phase = .saving
        }
        let endsAt = phase == .saving ? nil : VoiceNotePolicy.publishedEnd(
            startedAt: current.startedAt, lastUnpluggedAt: current.lastUnpluggedAt, power: current.power,
            activityStartedAt: sessionActivityStartedAt)
        return VoiceNoteStatus(phase: phase, startedAt: current.startedAt, endsAt: endsAt,
                               onPower: current.power == .connected)
    }

    /// The bounce screen's Stop: transcribe what was recorded.
    func userStopDictation() {
        guard let ticket = slot.ticket else { return }
        let now = environment.now()
        switch slot.phase {
        case .recording?: finish(ticket.requestID, now)
        case .starting?: endInProgress(.cancelled, now)
        default: break
        }
        flush(now)
    }

    func userCancelDictation() {
        let now = environment.now()
        endInProgress(.cancelled, now)
        flush(now)
    }

    // MARK: Words from corrections (ARCHITECTURE.md, "Custom dictionary")

    /// `.addedWord`: the keyboard wrote a word to add.
    func addedWordSignal() {
        guard isLaunched else { return }
        addedWords?.take()
    }

    /// The dictionary changed (a word saved from a correction included): what was kept for a correction goes.
    func dictionaryEdited() {
        addedWords?.releaseAll()
    }

    private func addedWordDecided() {
        let now = environment.now()
        needsPublish = true
        flush(now)
    }

    /// `protectedDataWillBecomeUnavailable`: latches the lock and cancels everything in flight, including
    /// a transcription that outlived its session. The session itself goes on until idle expiry.
    func deviceWillLock() {
        let now = environment.now()
        isLocked = true
        lockedAt = now
        // What is kept for a correction goes at a lock (ARCHITECTURE.md, "Custom dictionary", Words from corrections).
        addedWords?.releaseAll()
        guard isLaunched else { return }   // locked at launch: latched; run recovery publishes first
        // Intents and results are class A and unreadable while locked, so the dictation is cancelled, but
        // capture goes on with buffers dropped, as between dictations.
        if let phase = slot.phase, slot.isInProgress,
           let outcome = HostSessionPolicy.sessionEndOutcome(.deviceLocked, phase: phase) {
            endInProgress(outcome, now)
        }
        flush(now)
    }

    /// `protectedDataDidBecomeAvailable`: lifts the lock latch. An intent refused while locked stays known;
    /// one the host could not read meanwhile gets the normal freshness check.
    func deviceDidUnlock() {
        isLocked = false
    }

    func captureInterrupted() {
        let now = environment.now()
        endSession(.interrupted, now)
        flush(now)
    }

    /// Media services were reset: the audio session this app activated is gone (ARCHITECTURE.md, "Capture",
    /// Media services reset ends the session). A recording fails with `.audioSessionFailed`, since the microphone, not
    /// another app, failed; a finished recording is still transcribed. Capturing again needs a new
    /// foreground start.
    func captureMediaServicesReset() {
        let now = environment.now()
        endSession(.mediaServicesReset, now)
        flush(now)
    }

    /// Capture settings changed (the microphone choice). In the foreground during an active session the
    /// capture is reconfigured now; otherwise the change applies at the next session start. Never in the
    /// background, where nothing may be reconfigured on the user's behalf.
    func captureSettingsChanged() {
        guard isLaunched, session == .active else { return }
        let now = environment.now()
        guard noteForeground(now) else { return }
        reconfigureCapture(now)
        flush(now)
    }

    /// The engine of `generation` stopped or its configuration changed, within a surviving audio session
    /// (a route change, or the microphone choice re-asserted). The failure waits out `captureStallGrace`
    /// (an interruption arriving meanwhile wins), then the engine is restarted, in the background too. A
    /// report for an engine that has since been replaced is ignored.
    func captureFailed(generation: UInt64) {
        guard session == .active, generation == capture.engineGeneration else { return }
        noteCaptureFailure(environment.now())
    }

    /// The transcriber's model state changed. Acted on in the next turn, so a change made in the middle
    /// of a transition (preparation starts inside admission and `userStartSession`) never publishes a
    /// half-applied state or re-enters the transcriber.
    func modelStateChanged() {
        needsPublish = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = self.environment.now()
                self.releaseModelIfPending()
                // A runtime that is not ready keeps nothing for a correction: released, preparing anew or failed.
                if self.transcriber.modelState != .ready { self.addedWords?.releaseAll() }
                self.advanceNote(now)   // a preparing note records once the model is ready, or ends if it failed
                self.flush(now)
            }
        }
    }

    /// Releases the model now if nothing uses it; otherwise as soon as nothing does.
    func memoryWarning() {
        pendingModelRelease = true
        releaseModelIfPending()
        flush(environment.now())
    }

    /// Called on the capture thread with every event of the capture pipeline.
    nonisolated func captureDelivered(_ event: CaptureEvent) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(event) } }
    }

    // MARK: Reconciliation

    private func reconcilePass(_ trigger: ReconcileTrigger, _ now: Date) {
        lastReconcileAt = now
        // A request read past the deadline (no tick since, as after a resume) never joins the expired session.
        endSessionIfIdleExpired(now)
        guard let isForeground = HostSessionPolicy.reconcileForeground(
            trigger: trigger, isForeground: environment.isForeground(), hasBeenForeground: hasBeenForeground,
            sessionLive: session != .inactive) else { return }
        let intent = store.readIntent()
        switch HostReconciler.action(intent: intent, current: slot.current, knownRequestIDs: knownRequestIDs.set,
                                     isForeground: isForeground, sessionActive: session == .active, now: now) {
        case .none:
            break
        case .start(let requestID):
            if isNoteInProgress {
                // The microphone is the note's (ARCHITECTURE.md, "Voice notes").
                knownRequestIDs.insert(requestID)
                if slot.reject(requestID, error: .noteRecording, now: now) { needsPublish = true }
                break
            }
            if isLocked, let issuedAt = intent.value?.issuedAt,
               HostSessionPolicy.intentProvesUnlock(issuedAt: issuedAt, lockedAt: lockedAt) {
                // The keyboard wrote it on an unlocked iPhone; the unlock signal was missed or is late.
                isLocked = false
            }
            if isLocked {
                // Read while locked: refused for good, so it is never admitted after the unlock either.
                knownRequestIDs.insert(requestID)
                if slot.reject(requestID, error: .deviceLocked, now: now) { needsPublish = true }
            } else {
                admit(requestID, now)
            }
        case .finish(let requestID):
            finish(requestID, now)
        case .cancel(let requestID):
            guard slot.ticket?.requestID == requestID else { break }
            endInProgress(HostSessionPolicy.cancelOutcome(intentAction: intent.value?.action), now)
        case .reject(let requestID, let code):
            knownRequestIDs.insert(requestID)
            if slot.reject(requestID, error: code, now: now) { needsPublish = true }
        case .stopNote(let requestID):
            knownRequestIDs.insert(requestID)
            // Only a note that started before the keyboard asked: a stop never reaches a later note.
            if let current = note, current.isInProgress, let issuedAt = intent.value?.issuedAt,
               issuedAt >= current.startedAt {
                stopNote(.stopped, now)
            }
        }
    }

    private func admit(_ requestID: UUID, _ now: Date) {
        // A stopped note still waiting for its tail lets go of the buffer first, saving what arrived.
        if case .closing? = note?.phase { drainNote(now) }
        // The newest request wins; the old one's outcome is discarded by the fence.
        endInProgress(.cancelled(.superseded), now)
        knownRequestIDs.insert(requestID)
        // A new recording releases what was kept for an earlier dictation's correction, before its own stream opens.
        addedWords?.releaseAll()
        // With the model ready, the recording is transcribed while it is recorded; the buffer feeds the
        // stream exactly the samples it collects and cancels it with the recording.
        let generation = buffer.begin(requestID: requestID, stream: transcriber.beginStream(.dictation))
        let ticket = slot.admit(requestID, generation: generation, now: now)
        capture.recordingBoundary()
        idleSince = nil
        needsPublish = true
        // Admission starts preparing a model that is not prepared (released after a memory warning, or never
        // prepared), so it prepares while the user speaks, and the keyboard is told, instead of when the
        // recording ends. A missing model, or a failed one still backing off, fails the request at once.
        transcriber.prepare()
        if let code = HostSessionPolicy.admissionFailure(model: transcriber.modelState) {
            buffer.cancel(requestID: requestID)
            capture.recordingBoundary()
            slot.end(ticket, .failed, error: code, now: now)
            dictationEnded(now)
        } else if session == .inactive {
            startSession(now)
        }
    }

    /// Stops the recording at the current capture time and shows it as transcribing. The samples are
    /// drained once the tail (frames captured before now, still in flight) has arrived.
    private func finish(_ requestID: UUID, _ now: Date) {
        guard let ticket = slot.ticket, ticket.requestID == requestID, slot.phase == .recording else { return }
        guard buffer.close(requestID: requestID), slot.markTranscribing(ticket, now: now) else {
            endInProgress(.failed(.notRecording), now)
            return
        }
        recordingProgress = nil
        closing = (ticket, now)
        needsPublish = true
        // Nothing more can arrive at the cap or from a stopped engine.
        if buffer.hasReachedLimit || !capture.isRunning { drainClosing(now) }
    }

    private func drainClosing(_ now: Date) {
        guard let closing else { return }
        self.closing = nil
        guard slot.isCurrent(closing.ticket), slot.phase == .transcribing else { return }
        guard let audio = buffer.finishRecording(requestID: closing.ticket.requestID) else {
            endInProgress(.failed(.notRecording), now)
            return
        }
        capture.recordingBoundary()
        needsPublish = true
        transcribe(audio, closing.ticket)
    }

    /// Ends the request in progress, if any: stops its recording or transcription, so its samples are
    /// released, and publishes `outcome`.
    @discardableResult
    private func endInProgress(_ outcome: DictationOutcome, _ now: Date) -> Bool {
        guard let ticket = slot.ticket else { return false }
        buffer.cancel(requestID: ticket.requestID)
        capture.recordingBoundary()
        if closing?.ticket == ticket { closing = nil }
        if let transcription, transcription.ticket == ticket {
            transcription.task.cancel()
            transcription.endBackgroundTask.run()
            self.transcription = nil
        }
        slot.end(ticket, outcome.phase, error: outcome.error, now: now)
        dictationEnded(now)
        return true
    }

    private func dictationEnded(_ now: Date) {
        idleSince = session == .active && !isNoteInProgress ? now : nil
        recordingProgress = nil
        needsPublish = true
        releaseModelIfPending()
    }

    // MARK: Recording

    private func handle(_ event: CaptureEvent) {
        let now = environment.now()
        switch event {
        case .started(let generation):
            if slot.markRecording(generation: generation, now: now) { needsPublish = true }
        case .reachedLimit(let generation):
            guard let ticket = slot.ticket, ticket.generation == generation else { break }
            _ = slot.markRecording(generation: generation, now: now)   // the limit can arrive with the first buffer
            finish(ticket.requestID, now)
        case .tailComplete(let generation):
            if closing?.ticket.generation == generation { drainClosing(now) }
            if case .closing? = note?.phase, note?.bufferGeneration == generation { drainNote(now) }
        case .conversionFailed(let generation, let engine):
            // A note's converter is rebuilt with the engine, and the note goes on once input flows again; input that
            // keeps failing to convert, with nothing converted between, stops it after as many recoveries as an engine
            // gets (ARCHITECTURE.md, "Voice notes").
            if engine == capture.engineGeneration, note?.phase == .recording, note?.bufferGeneration == generation {
                let converted = buffer.recordedDuration
                let failures = note?.convertedAtLastFailure == converted ? (note?.conversionFailures ?? 0) + 1 : 1
                note?.conversionFailures = failures
                note?.convertedAtLastFailure = converted
                if failures > HostSessionPolicy.maxRecoveriesWithoutInput { stopNote(.captureFailed, now) }
                noteCaptureFailure(now)
                break
            }
            // A pipeline of an engine since replaced (a live reconfiguration or restart) no longer converts.
            guard engine == capture.engineGeneration, let ticket = slot.ticket, ticket.generation == generation,
                  slot.phase == .starting || slot.phase == .recording else { break }
            endInProgress(.failed(.audioSessionFailed), now)
            noteCaptureFailure(now)   // a rebuilt engine gets a fresh converter
        }
        flush(now)
    }

    /// Watchdog, the duration cap by samples and by elapsed time, and a recording that stopped growing.
    private func superviseDictation(_ now: Date, foreground: Bool) {
        guard let current = slot.current, let ticket = slot.ticket,
              current.phase == .starting || current.phase == .recording else {
            recordingProgress = nil
            return
        }
        if let reason = HostWatchdog.stopReason(current: current, presence: store.readPresence(),
                                                isForeground: foreground, lastForegroundAt: lastForegroundAt, now: now) {
            endInProgress(HostSessionPolicy.watchdogOutcome(reason), now)
            return
        }
        guard current.phase == .recording else { return }
        if buffer.hasReachedLimit || HostSessionPolicy.hasExceededMaxDuration(startedAt: current.startedAt, now: now) {
            finish(current.requestID, now)
            return
        }
        let duration = buffer.recordedDuration
        if let progress = recordingProgress, progress.generation == ticket.generation, progress.duration == duration,
           progress.since <= now {
            guard HostSessionPolicy.isStarved(lastInputAt: progress.since, now: now) else { return }
            // Running but starved, or every buffer failing to convert: the recording cannot go on.
            endInProgress(.failed(.audioSessionFailed), now)
            noteCaptureFailure(now)
        } else {
            recordingProgress = (ticket.generation, duration, now)
        }
    }

    // MARK: Capture supervision

    private func noteCaptureFailure(_ now: Date) {
        if captureFailingSince == nil { captureFailingSince = now }
    }

    /// A stopped or starved engine, or a reported failure, is restarted once `captureStallGrace` has
    /// passed without an interruption ending the session first.
    private func superviseCapture(_ now: Date) {
        guard session == .active else {
            captureFailingSince = nil
            return
        }
        let lastInput = [capture.lastBufferAt, captureStartedAt].compactMap { $0 }.max()
        if let lastBuffer = capture.lastBufferAt, let started = captureStartedAt, lastBuffer > started {
            recoveriesWithoutInput = 0
        }
        if !capture.isRunning || lastInput.map({ HostSessionPolicy.isStarved(lastInputAt: $0, now: now) }) == true {
            noteCaptureFailure(now)
        }
        guard let since = captureFailingSince else { return }
        let pending = now.timeIntervalSince(since)
        if pending < 0 || pending >= HostSessionPolicy.captureStallGrace { recoverCapture(now) }
    }

    /// Applies changed capture settings in the foreground; the session ends if that fails.
    private func reconfigureCapture(_ now: Date) {
        do {
            try capture.reconfigure()
        } catch {
            endSession(.engineFailed, now)
            return
        }
        captureStartedAt = now
        captureFailingSince = nil
        needsPublish = true
    }

    /// While the audio session is active the engine may be rebuilt even in the background or locked:
    /// `restart()` never activates anything. In the foreground, unlocked, a full start also reconfigures
    /// the audio session. The session ends if that fails, or if recoveries keep producing no input.
    private func recoverCapture(_ now: Date) {
        guard session == .active else { return }
        captureFailingSince = nil
        guard recoveriesWithoutInput < HostSessionPolicy.maxRecoveriesWithoutInput else {
            endSession(.engineFailed, now)
            return
        }
        do {
            if environment.isForeground(), !isLocked {
                capture.stop()
                try capture.start()
            } else {
                try capture.restart()
            }
        } catch {
            endSession(.engineFailed, now)
            return
        }
        recoveriesWithoutInput += 1
        captureStartedAt = now
        needsPublish = true
    }

    // MARK: Transcription

    private func transcribe(_ audio: RecordedAudio, _ ticket: DictationTicket) {
        let endBackgroundTask = OnceAction()
        endBackgroundTask.action = environment.beginBackgroundTask { [weak self] in
            self?.backgroundTimeExpired(ticket)
            endBackgroundTask.run()
        }
        let transcriber = self.transcriber
        let task = Task { [weak self] in
            let outcome: Result<DictationTranscript, Error>
            do { outcome = .success(try await transcriber.transcribe(audio)) } catch { outcome = .failure(error) }
            self?.transcriptionFinished(ticket, outcome)
            endBackgroundTask.run()
        }
        transcription = Transcription(ticket: ticket, task: task, endBackgroundTask: endBackgroundTask)
    }

    private func transcriptionFinished(_ ticket: DictationTicket, _ outcome: Result<DictationTranscript, Error>) {
        if transcription?.ticket == ticket { transcription = nil }
        // Superseded, cancelled or expired meanwhile: the outcome is discarded, and so is what was kept for it.
        guard slot.isCurrent(ticket), slot.phase == .transcribing else {
            if case .success(let transcript) = outcome, let id = transcript.correctionID { transcriber.releaseCorrection(id) }
            return
        }
        let now = environment.now()
        switch outcome {
        case .success(let transcript):
            let formatted = environment.formatTranscript(transcript.text, settings.pressEnterEnabled,
                                                         settings.spokenDelimitersEnabled, settings.spokenNumbersEnabled)
            let result = DictationResult(requestID: ticket.requestID, hostRunID: hostRunID, text: formatted.text,
                                         pressEnter: formatted.pressEnter, createdAt: now)
            do {
                // Written before `completed` is published, so a keyboard that sees completed finds it.
                try store.writeResult(result)
                notifier?.post(.result)
                slot.end(ticket, .completed, now: now)
                // The text the keyboard will insert is the one a correction is checked against.
                if let id = transcript.correctionID {
                    if let addedWords {
                        addedWords.keep(requestID: ticket.requestID, correctionID: id, text: formatted.text)
                    } else {
                        transcriber.releaseCorrection(id)
                    }
                }
            } catch {
                slot.end(ticket, .failed, error: .transcriptionFailed, now: now)
                if let id = transcript.correctionID { transcriber.releaseCorrection(id) }
            }
        case .failure(let error):
            slot.end(ticket, .failed, error: (error as? TranscriptionFailure)?.errorCode ?? .transcriptionFailed, now: now)
        }
        dictationEnded(now)
        flush(now)
    }

    private func backgroundTimeExpired(_ ticket: DictationTicket) {
        guard slot.isCurrent(ticket) else { return }
        let now = environment.now()
        endInProgress(.failed(.backgroundTimeExpired), now)
        flush(now)
    }

    private func releaseModelIfPending() {
        guard pendingModelRelease, !slot.isInProgress, note == nil else { return }
        if transcriber.releaseIfIdle() {
            pendingModelRelease = false
            needsPublish = true
        }
    }

    // MARK: Session

    /// `inBackground`: the session control's start, with permission granted and the latch clear, which iOS lets
    /// capture start in the background.
    private func startSession(_ now: Date, inBackground: Bool = false) {
        guard session == .inactive else { return }
        sessionGeneration &+= 1
        session = .starting
        sessionID = UUID()
        sessionError = nil
        controlStartRequestedAt = nil
        needsPublish = true
        continueSessionStart(sessionGeneration, now, inBackground: inBackground)
    }

    private func continueSessionStart(_ generation: UInt64, _ now: Date, inBackground: Bool = false) {
        guard generation == sessionGeneration, session == .starting else { return }
        // A session never starts in the background (capture and the permission prompt need the front), except
        // the session control's, nor while locked.
        guard environment.isForeground() || inBackground, !isLocked else {
            pendingStart = generation
            return
        }
        pendingStart = nil
        switch capture.permission {
        case .granted:
            activateCapture(now)
        case .denied:
            endSession(.startFailed(.microphonePermissionDenied), now)
        case .undetermined:
            let capture = self.capture
            Task { [weak self] in
                let granted = await capture.requestPermission()
                guard let self, generation == self.sessionGeneration, self.session == .starting else { return }
                let now = self.environment.now()
                if !granted {
                    self.endSession(.startFailed(.microphonePermissionDenied), now)
                } else if self.environment.isForeground(), !self.isLocked {
                    self.activateCapture(now)
                } else {
                    self.pendingStart = generation
                }
                self.flush(now)
            }
        }
    }

    private func activateCapture(_ now: Date) {
        do {
            try capture.start()
        } catch {
            endSession(.startFailed(.audioSessionFailed), now)
            return
        }
        session = .active
        captureStartedAt = now
        captureFailingSince = nil
        recoveriesWithoutInput = 0
        if !slot.isInProgress, !isNoteInProgress { idleSince = now }
        needsPublish = true
        advanceNote(now)
    }

    private func endSessionIfIdleExpired(_ now: Date) {
        guard session == .active, !slot.isInProgress, !isNoteInProgress,
              HostSessionPolicy.isIdleExpired(idleSince: idleSince, duration: settings.sessionDuration, now: now) else { return }
        endSession(.idleExpired, now)
    }

    private func endSession(_ reason: SessionEndReason, _ now: Date) {
        guard session != .inactive else { return }
        sessionGeneration &+= 1
        pendingStart = nil
        controlStartRequestedAt = nil
        if let phase = slot.phase, slot.isInProgress,
           let outcome = HostSessionPolicy.sessionEndOutcome(reason, phase: phase) {
            endInProgress(outcome, now)
        }
        // A finished recording that survives the session end is transcribed with the tail it has; no more
        // input will arrive. So is a note's.
        drainClosing(now)
        noteSessionEnded(reason, now)
        capture.stop()
        // Anything still held belongs to a request that just ended; a transcription has its own copy.
        buffer.cancelAll()
        capture.recordingBoundary()
        session = .inactive
        sessionID = nil
        sessionError = HostSessionPolicy.sessionError(after: reason)
        idleSince = nil
        captureFailingSince = nil
        captureStartedAt = nil
        recoveriesWithoutInput = 0
        store.purgeExpiredResults(now: now)
        // What is kept for a correction goes with the session; a waiting added word is taken (and decided) now.
        addedWords?.releaseAll()
        addedWords?.take()
        needsPublish = true
    }

    // MARK: Publishing

    @discardableResult
    private func noteForeground(_ now: Date) -> Bool {
        let foreground = environment.isForeground()
        if foreground {
            hasBeenForeground = true
            lastForegroundAt = now
        }
        return foreground
    }

    private func flush(_ now: Date) {
        guard needsPublish else { return }
        needsPublish = false
        let status = HostSessionPolicy.status(
            hostRunID: hostRunID, sessionID: sessionID, session: session, captureRunning: capture.isRunning,
            lastBufferAt: capture.lastBufferAt, idleSince: idleSince, sessionDuration: settings.sessionDuration,
            model: transcriber.modelState, dictation: slot.current, level: buffer.level, error: sessionError,
            voiceNote: voiceNote, addedWord: addedWords?.status(now: now), now: now)
        lastStatusAt = now
        // A failed write is retried by the next heartbeat; the reader treats a stale one as a dead host.
        if (try? store.writeStatus(status)) != nil { notifier?.post(.status) }
        onPublish?(status)
        onChange?()
        let changes = noteChanges
        noteChanges = []
        for change in changes { onNoteChange?(change) }
    }
}

/// The voice note as the core holds it (ARCHITECTURE.md, "Voice notes"). It holds no text: the writer seals each
/// piece the moment it arrives.
@MainActor
private struct ActiveNote {
    enum Phase: Equatable {
        case preparing
        case recording
        /// Stopped; waiting for the tail captured before the stop.
        case closing(since: Date)
        /// The stream finishes and writes its last piece.
        case saving
    }

    let generation: UInt64
    let writer: NoteRunWriter
    let startedAt: Date
    var power: PowerSource
    var phase = Phase.preparing
    var lastUnpluggedAt: Date?
    /// The sample buffer's recording that feeds the stream, while recording or closing.
    var recordingID: UUID?
    var bufferGeneration: UInt64?
    var stream: SpeechStream?
    /// What the note ends with once saved.
    var reason = NoteEndReason.stopped
    /// Conversion failures in a row with nothing converted between them, and how much had been converted at the last.
    var conversionFailures = 0
    var convertedAtLastFailure: TimeInterval?
    var feedEnded = false
    /// Whether the stream's finish succeeded, once it returned.
    var finished: Bool?
    var endBackgroundTask: OnceAction?

    init(generation: UInt64, writer: NoteRunWriter, startedAt: Date, power: PowerSource) {
        self.generation = generation
        self.writer = writer
        self.startedAt = startedAt
        self.power = power
    }

    /// Preparing or recording: the note holds the microphone.
    var isInProgress: Bool { phase == .preparing || phase == .recording }
}

/// Runs its action at most once, however many paths reach it.
@MainActor
private final class OnceAction {
    var action: (@MainActor () -> Void)?

    func run() {
        let action = self.action
        self.action = nil
        action?()
    }
}
