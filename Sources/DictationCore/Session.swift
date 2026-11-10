import Foundation

/// The dictation state machine (ARCHITECTURE.md, section 3). One pure function decides every change to
/// `SessionState` and returns the work to do as `SessionEffect` values. It reads no clock, draws no random numbers
/// and touches no port, so it can be tested event by event.
public enum Session {
    /// At most this many dictations exist at once: the one recording plus the pipeline (rule 1).
    public static let maximumDictations = 3

    /// Applies one event to the state and returns the effects to perform, in order.
    ///
    /// An event that names a dictation the state no longer holds, a timer that is no longer armed, or a replay
    /// that no longer owns the output is dropped here, before any rule runs, and changes nothing.
    public static func reduce(_ state: inout SessionState, _ event: SessionEvent,
                              settings: SessionSettings) -> [SessionEffect] {
        if case .trigger(let trigger, let time) = event {
            return handle(&state, trigger, at: time, settings: settings).effects
        }
        guard isCurrent(event, in: state) else { return [] }
        var step = Step(state: state, settings: settings)
        step.apply(event)
        step.finish()
        state = step.state
        return step.effects
    }

    /// Applies a trigger, as `reduce` does, and also says whether it acted. `SessionRuntime` uses this for
    /// `TriggerHandling.handle`, whose result decides whether Escape is consumed.
    public static func handle(_ state: inout SessionState, _ trigger: TriggerEvent, at time: TimeInterval,
                              settings: SessionSettings) -> TriggerOutcome {
        var step = Step(state: state, settings: settings)
        let acted = step.trigger(trigger, at: time)
        step.finish()
        state = step.state
        return TriggerOutcome(effects: step.effects, acted: acted)
    }

    /// The one place stale events are recognised.
    static func isCurrent(_ event: SessionEvent, in state: SessionState) -> Bool {
        switch event {
        case .capture(let id, _), .transcript(let id, _), .insertion(let id, _):
            state.holds(id)
        case .timer(let timer):
            state.isArmed(timer)
        case .reinsertion(let replay, _):
            state.output == .replaying(replay)
        case .trigger, .microphoneAccess, .engine, .forgetLast:
            true
        }
    }
}

/// One application of the rules: the state being changed and the effects collected so far.
private struct Step {
    var state: SessionState
    let settings: SessionSettings
    var effects: [SessionEffect] = []

    init(state: SessionState, settings: SessionSettings) {
        self.state = state
        self.settings = settings
        // The arm belongs to prompt mode; turning the setting off forgets it.
        if !settings.promptMode { self.state.tap = nil }
    }

    mutating func emit(_ effect: SessionEffect) { effects.append(effect) }

    /// Rule 8, applied after every event: whenever the output is free and the oldest item is ready, insert it.
    mutating func finish() {
        guard state.output == .free, let head = state.pipeline.first, case .ready(let speech) = head.phase else {
            return
        }
        state.pipeline.removeFirst()
        state.output = .inserting(InsertingDictation(id: head.id, style: head.style, speech: speech))
        emit(.insert(InsertionRequest(id: head.id, speech: speech, style: head.style,
                                      restoreClipboard: settings.restoreClipboard)))
    }

    // MARK: Events other than triggers

    mutating func apply(_ event: SessionEvent) {
        switch event {
        case .trigger(let trigger, let time):
            _ = self.trigger(trigger, at: time)
        case .capture(let id, let report):
            capture(id, report)
        case .transcript(let id, let result):
            transcript(id, result)
        case .insertion(let id, let report):
            insertion(id, report)
        case .reinsertion:
            // Rule 11: a replay is not recorded and is never watched; its report only frees the output.
            state.output = .free
        case .timer(let timer):
            fire(timer)
        case .microphoneAccess(let access):
            microphoneAccess(access)
        case .engine(let readiness):
            // Rule 10: an engine that fails while a dictation records does not interrupt it.
            state.engine = readiness
        case .forgetLast:
            state.lastText = nil
        }
    }

    /// Rules 3 and 4, and rule 10 for a capture that fails while starting.
    mutating func capture(_ id: DictationID, _ report: CaptureReport) {
        switch state.capture {
        case .starting(let live, let stopRequested) where live.id == id:
            switch report {
            case .started:
                emit(.cancelTimer(.captureStart(id)))
                if stopRequested {
                    drain(live)
                } else {
                    state.capture = .recording(live)
                    emit(.setTimer(.captureLimit(id), after: SessionTiming.captureLimit))
                }
            case .failed:
                discardLive(live, firedTimer: nil)
                show(.microphoneUnavailable)
            case .stalled, .interrupted, .ended:
                // The runtime reports `started` before anything the capture says, so these cannot come first.
                // Should one, the start timer still ends the dictation.
                break
            }
            return
        case .recording(let live) where live.id == id:
            switch report {
            case .started:
                break
            case .stalled, .interrupted, .failed:
                stop(live, firedTimer: nil)
            case .ended(let summary):
                // The capture ended without being asked to. It has nothing more to deliver, so the dictation goes
                // straight on to its transcript.
                emit(.stopCapture(id))
                emit(.cancelTimer(.captureLimit(id)))
                state.capture = .idle
                state.pipeline.append(PipelineItem(id: id, style: live.style,
                                                   phase: .draining(drainTimerArmed: false)))
                captureEnded(at: state.pipeline.count - 1, summary)
            }
            return
        default:
            break
        }
        // Rule 4: only `capture.ended` finishes a draining dictation. A capture event for a dictation that is not
        // starting, recording or draining does nothing.
        guard case .ended(let summary) = report,
              let index = state.pipeline.firstIndex(where: { $0.id == id }),
              case .draining(let drainTimerArmed) = state.pipeline[index].phase else { return }
        if drainTimerArmed { emit(.cancelTimer(.captureDrain(id))) }
        captureEnded(at: index, summary)
    }

    /// Rule 4: the dictation at `index` has all its audio. Too little is a tap, discarded without a word.
    mutating func captureEnded(at index: Int, _ summary: CaptureSummary) {
        let id = state.pipeline[index].id
        if summary.duration < SessionTiming.minimumAudio {
            state.pipeline.remove(at: index)
            emit(.discard(id))
            complete(id, .discarded)
        } else {
            state.pipeline[index].phase = .transcribing(audio: summary.duration)
            emit(.finishStream(id))
        }
    }

    /// Rules 8 and 10.
    mutating func transcript(_ id: DictationID, _ result: Result<SpeechResult, SpeechFailure>) {
        guard let index = state.pipeline.firstIndex(where: { $0.id == id }),
              case .transcribing(let audio) = state.pipeline[index].phase else { return }
        switch result {
        case .success(let speech) where speech.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            state.pipeline.remove(at: index)
            if audio >= SessionTiming.nothingHeardAfter { show(.nothingHeard) }
            complete(id, .nothingHeard, speech: speech)
        case .success(let speech):
            state.pipeline[index].phase = .ready(speech)
        case .failure(let failure):
            state.pipeline.remove(at: index)
            emit(.record(RunLogEntry(dictation: id, heard: "", text: "", outcome: .transcriptionFailed)))
            show(.transcriptionFailed)
            complete(id, .transcriptionFailed(failure))
        }
    }

    /// Rule 9. Whatever the outcome, the item leaves and nothing is posted for it again.
    mutating func insertion(_ id: DictationID, _ report: InsertionReport) {
        guard case .inserting(let item) = state.output, item.id == id else { return }
        state.output = .free
        let processed = report.processed
        let heard = processed?.heard ?? item.speech.text
        let text = processed?.text ?? ""
        switch report.outcome {
        case .inserted:
            emit(.record(RunLogEntry(dictation: id, heard: heard, text: text, outcome: .inserted)))
            remember(text)
        case .leftOnClipboard(let reason):
            emit(.record(RunLogEntry(dictation: id, heard: heard, text: text, outcome: .leftOnClipboard)))
            remember(text)
            show(.leftOnClipboard(reason))
        case .nothingToInsert:
            break
        case .failed(let failure):
            emit(.record(RunLogEntry(dictation: id, heard: heard, text: text, outcome: .insertionFailed)))
            show(.insertionFailed(failure))
        }
        complete(id, .insertion(report.outcome), speech: item.speech, processed: processed)
    }

    /// A dictation that only pressed Return leaves the remembered text as it was.
    mutating func remember(_ text: String) {
        if !text.isEmpty { state.lastText = text }
    }

    /// Only armed timers get here (see `Session.isCurrent`).
    mutating func fire(_ timer: TimerID) {
        switch timer {
        case .captureStart:
            // Rule 10.
            guard let live = state.capture.live else { return }
            discardLive(live, firedTimer: timer)
            show(.microphoneUnavailable)
        case .captureLimit:
            // Rule 4.
            guard let live = state.capture.live else { return }
            stop(live, firedTimer: timer)
        case .captureDrain(let id):
            // Rule 4: abort only. The capture still delivers what it had, then reports `ended`.
            guard let index = state.pipeline.firstIndex(where: { $0.id == id }) else { return }
            state.pipeline[index].phase = .draining(drainTimerArmed: false)
            emit(.abortCapture(id))
        case .notice:
            state.notice = nil
        }
    }

    /// Rule 2: the answer to the permission prompt, or the access as it was read.
    mutating func microphoneAccess(_ access: MicrophoneAccess) {
        state.microphone = access
        guard case .awaitingPermission(let intent) = state.capture else { return }
        switch access {
        case .granted:
            state.capture = .idle
            // A press that was released, abandoned or cancelled cleared the intent: it is never revived.
            if let intent, admitsStart() {
                begin(intent.mode, style: .plain, pressTime: intent.pressTime, mayArmTap: false)
            }
        case .denied:
            state.capture = .idle
            show(.microphoneDenied)
        case .unknown:
            // Still undecided: the prompt is still up.
            break
        }
    }

    // MARK: Triggers

    /// Returns whether the trigger acted.
    mutating func trigger(_ trigger: TriggerEvent, at time: TimeInterval) -> Bool {
        // Rule 5: every trigger uses up or clears the arm; a hold press may use it, a quick release may set it.
        let arm = state.tap
        state.tap = nil
        if case .holdReleased = trigger {} else { forbidTapArm() }

        switch trigger {
        case .holdPressed:
            return holdPressed(at: time, arm: arm)
        case .togglePressed:
            return togglePressed(at: time)
        case .holdReleased(let origin):
            return holdReleased(origin, at: time)
        case .holdAbandoned:
            return holdAbandoned()
        case .cancelPressed, .pillCancelClicked:
            return cancel()
        case .pillStopClicked:
            return pillStopClicked()
        case .pasteAgainPressed:
            return pasteAgain()
        case .systemInterrupted:
            return systemInterrupted()
        }
    }

    /// Rule 5: a hold interrupted by another trigger can no longer arm the double tap.
    mutating func forbidTapArm() {
        switch state.capture {
        case .starting(var live, let stopRequested):
            live.mayArmTap = false
            state.capture = .starting(live, stopRequested: stopRequested)
        case .recording(var live):
            live.mayArmTap = false
            state.capture = .recording(live)
        case .idle, .awaitingPermission:
            break
        }
    }

    mutating func holdPressed(at time: TimeInterval, arm: TapArm?) -> Bool {
        switch state.capture {
        case .idle:
            start(.hold, at: time, arm: arm)
            return true
        case .awaitingPermission:
            // Rule 2: a new press replaces the intent.
            state.capture = .awaitingPermission(PermissionIntent(mode: .hold, pressTime: time))
            return true
        case .starting, .recording:
            // Rule 7: a hold press during a toggle recording is ignored (and a hold cannot be pressed twice).
            return false
        }
    }

    mutating func togglePressed(at time: TimeInterval) -> Bool {
        switch state.capture {
        case .idle:
            start(.toggle, at: time, arm: nil)
            return true
        case .awaitingPermission(let intent):
            // Rule 2: a second toggle press clears the intent; any other press replaces it.
            state.capture = .awaitingPermission(
                intent?.mode == .toggle ? nil : PermissionIntent(mode: .toggle, pressTime: time))
            return true
        case .starting(let live, _), .recording(let live):
            // Rule 7: a toggle press during a hold recording is ignored.
            guard live.mode == .toggle else { return false }
            requestStop(live)
            return true
        }
    }

    mutating func holdReleased(_ origin: ReleaseOrigin, at time: TimeInterval) -> Bool {
        if let live = state.capture.live, live.mode == .hold {
            if settings.promptMode && time < live.pressTime + SessionTiming.tapHold {
                // Rule 5: a tap. It is discarded whether it was starting or recording.
                discardLive(live, firedTimer: nil)
                if live.mayArmTap && origin == .keyUp { state.tap = TapArm(releaseTime: time) }
            } else {
                requestStop(live)
            }
            return true
        }
        if case .awaitingPermission(let intent?) = state.capture, intent.mode == .hold {
            state.capture = .awaitingPermission(nil)
            return true
        }
        // Rule 7: no hold in progress, so a key still down after the limit starts nothing.
        return false
    }

    mutating func holdAbandoned() -> Bool {
        // Rule 7: the hold was the start of a chord. Discard it like a cancel, with no notice.
        if let live = state.capture.live, live.mode == .hold {
            discardLive(live, firedTimer: nil)
            return true
        }
        if case .awaitingPermission(let intent?) = state.capture, intent.mode == .hold {
            state.capture = .awaitingPermission(nil)
            return true
        }
        return false
    }

    /// Rule 6. Returns whether anything was cancelled.
    mutating func cancel() -> Bool {
        switch state.capture {
        case .starting(let live, _), .recording(let live):
            discardLive(live, firedTimer: nil)
            return true
        case .awaitingPermission(let intent):
            state.capture = .awaitingPermission(nil)
            return discardPipeline() || intent != nil
        case .idle:
            return discardPipeline()
        }
    }

    mutating func pillStopClicked() -> Bool {
        // Rule 4: the pill is Stop in toggle mode only.
        guard let live = state.capture.live, live.mode == .toggle else { return false }
        requestStop(live)
        return true
    }

    /// Rule 11.
    mutating func pasteAgain() -> Bool {
        guard state.capture == .idle, state.pipeline.isEmpty, state.output == .free,
              let text = state.lastText else { return false }
        let replay = ReplayID(state.nextReplay)
        state.nextReplay += 1
        state.output = .replaying(replay)
        emit(.reinsert(replay, text: text, restoreClipboard: settings.restoreClipboard))
        return true
    }

    /// Rule 7: stop a recording in either mode, discard one still starting, clear a waiting intent.
    mutating func systemInterrupted() -> Bool {
        switch state.capture {
        case .starting(let live, _):
            discardLive(live, firedTimer: nil)
            return true
        case .recording(let live):
            stop(live, firedTimer: nil)
            return true
        case .awaitingPermission(let intent):
            state.capture = .awaitingPermission(nil)
            return intent != nil
        case .idle:
            return false
        }
    }

    // MARK: Starting and stopping

    /// Rules 1, 2 and 5 for a press while the microphone is free.
    mutating func start(_ mode: TriggerMode, at time: TimeInterval, arm: TapArm?) {
        // Nothing at all in progress: the microphone is free (it is, to get here), and nothing waits or inserts.
        let nothingInProgress = state.pipeline.isEmpty && state.output == .free
        guard admitsStart() else { return }
        if state.microphone == .unknown {
            state.capture = .awaitingPermission(PermissionIntent(mode: mode, pressTime: time))
            emit(.requestMicrophoneAccess)
            return
        }
        let doubleTap = mode == .hold && settings.promptMode && nothingInProgress && arm?.admits(time) == true
        let mayArmTap = mode == .hold && settings.promptMode && nothingInProgress && !doubleTap
        begin(mode, style: doubleTap ? .prompt : .plain, pressTime: time, mayArmTap: mayArmTap)
    }

    /// Rule 1's refusals. Shows the notice and returns false when a dictation may not start.
    mutating func admitsStart() -> Bool {
        if state.dictationCount >= Session.maximumDictations {
            show(.busy)
            return false
        }
        if state.microphone == .denied {
            show(.microphoneDenied)
            return false
        }
        if case .failed(let failure) = state.engine {
            show(.engineFailed(failure))
            return false
        }
        return true
    }

    /// Rule 1: allocate the id and ask for the microphone and the stream. Starting dismisses the notice (rule 12).
    mutating func begin(_ mode: TriggerMode, style: DictationStyle, pressTime: TimeInterval, mayArmTap: Bool) {
        let id = DictationID(state.nextDictation)
        state.nextDictation += 1
        dismissNotice()
        let live = LiveDictation(id: id, mode: mode, style: style, pressTime: pressTime, mayArmTap: mayArmTap)
        state.capture = .starting(live, stopRequested: false)
        emit(.startCapture(id, CaptureRequest(deviceID: settings.microphoneID)))
        emit(.openStream(id, retainForCorrection: settings.retainForCorrection))
        emit(.setTimer(.captureStart(id), after: SessionTiming.captureStart))
    }

    /// A stop asked for by the user: applied now while recording, remembered while starting (rule 3).
    mutating func requestStop(_ live: LiveDictation) {
        if case .starting(_, _) = state.capture {
            state.capture = .starting(live, stopRequested: true)
        } else {
            stop(live, firedTimer: nil)
        }
    }

    /// Rule 4 for a recording dictation.
    mutating func stop(_ live: LiveDictation, firedTimer: TimerID?) {
        drain(live, cancellingLimit: firedTimer != .captureLimit(live.id))
    }

    /// Rule 4: ask the capture to finish, give it 2 s, and free the microphone slot at once. A dictation stopped
    /// as it starts never had a limit timer.
    mutating func drain(_ live: LiveDictation, cancellingLimit: Bool = false) {
        emit(.stopCapture(live.id))
        if cancellingLimit { emit(.cancelTimer(.captureLimit(live.id))) }
        emit(.setTimer(.captureDrain(live.id), after: SessionTiming.captureDrain))
        state.pipeline.append(PipelineItem(id: live.id, style: live.style, phase: .draining(drainTimerArmed: true)))
        state.capture = .idle
    }

    /// Throws away the dictation holding the microphone and cancels its phase's timer, unless that timer is the
    /// one firing now.
    mutating func discardLive(_ live: LiveDictation, firedTimer: TimerID?) {
        let phaseTimer: TimerID
        if case .starting = state.capture {
            phaseTimer = .captureStart(live.id)
        } else {
            phaseTimer = .captureLimit(live.id)
        }
        if phaseTimer != firedTimer { emit(.cancelTimer(phaseTimer)) }
        state.capture = .idle
        emit(.discard(live.id))
        complete(live.id, .discarded)
    }

    /// Rule 6: every pipeline item is discarded, draining ones included. The item being inserted is not in the
    /// pipeline, so a paste is never retracted. Returns whether there was anything to discard.
    mutating func discardPipeline() -> Bool {
        let items = state.pipeline
        state.pipeline.removeAll()
        for item in items {
            if item.phase == .draining(drainTimerArmed: true) { emit(.cancelTimer(.captureDrain(item.id))) }
            emit(.discard(item.id))
            if case .ready(let speech) = item.phase {
                complete(item.id, .discarded, speech: speech)
            } else {
                complete(item.id, .discarded)
            }
        }
        return !items.isEmpty
    }

    mutating func complete(_ id: DictationID, _ ending: DictationEnding, speech: SpeechResult? = nil,
                           processed: ProcessedDictation? = nil) {
        emit(.complete(DictationCompletion(id: id, ending: ending, speech: speech, processed: processed)))
    }

    // MARK: Notices

    /// Rule 12: one notice at a time, each with its own timer.
    mutating func show(_ message: NoticeMessage) {
        dismissNotice()
        let id = NoticeID(state.nextNotice)
        state.nextNotice += 1
        state.notice = Notice(id: id, message: message)
        emit(.setTimer(.notice(id), after: message.kind.lifetime))
    }

    mutating func dismissNotice() {
        guard let notice = state.notice else { return }
        emit(.cancelTimer(.notice(notice.id)))
        state.notice = nil
    }
}
