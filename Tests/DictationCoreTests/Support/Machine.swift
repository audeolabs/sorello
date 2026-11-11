import DictationCore
import Foundation
import Testing

/// Drives `Session.reduce` the way the runtime does and checks, after every step, the invariants section 3 promises
/// (see `Ledger`). Every reducer test goes through this, so every test also checks the invariants.
struct Machine {
    var state = SessionState()
    var settings: SessionSettings
    var ledger = Ledger()
    /// Every effect emitted so far, in order.
    var log: [SessionEffect] = []

    /// A session whose microphone and engine have already reported, so tests start from the common case.
    init(microphone: MicrophoneAccess = .granted, engine: EngineReadiness = .ready,
         settings: SessionSettings = SessionSettings()) {
        self.settings = settings
        send(.microphoneAccess(microphone))
        send(.engine(engine))
    }

    @discardableResult
    mutating func send(_ event: SessionEvent, sourceLocation: SourceLocation = #_sourceLocation) -> [SessionEffect] {
        if case .trigger(let trigger, let time) = event {
            return self.trigger(trigger, at: time, sourceLocation: sourceLocation).effects
        }
        let before = state
        let effects = Session.reduce(&state, event, settings: settings)
        ledger.check(before: before, event: event, after: state, effects: effects, sourceLocation: sourceLocation)
        log += effects
        return effects
    }

    @discardableResult
    mutating func trigger(_ trigger: TriggerEvent, at time: TimeInterval,
                          sourceLocation: SourceLocation = #_sourceLocation) -> TriggerOutcome {
        let before = state
        let outcome = Session.handle(&state, trigger, at: time, settings: settings)
        var viaReduce = before
        let effects = Session.reduce(&viaReduce, .trigger(trigger, at: time), settings: settings)
        #expect(viaReduce == state && effects == outcome.effects, "reduce and handle agree", sourceLocation: sourceLocation)
        ledger.check(before: before, event: .trigger(trigger, at: time), after: state, effects: outcome.effects,
                     sourceLocation: sourceLocation)
        log += outcome.effects
        return outcome
    }

    // MARK: Conveniences

    /// Presses Hold to Talk or Tap to Toggle and returns the dictation it started, if any.
    @discardableResult
    mutating func press(_ mode: TriggerMode, at time: TimeInterval,
                        sourceLocation: SourceLocation = #_sourceLocation) -> DictationID? {
        let effects = trigger(mode == .hold ? .holdPressed : .togglePressed, at: time, sourceLocation: sourceLocation)
            .effects
        return effects.startedDictation
    }

    @discardableResult
    mutating func release(at time: TimeInterval, _ origin: ReleaseOrigin = .keyUp,
                          sourceLocation: SourceLocation = #_sourceLocation) -> [SessionEffect] {
        trigger(.holdReleased(origin), at: time, sourceLocation: sourceLocation).effects
    }

    @discardableResult
    mutating func started(_ id: DictationID, sourceLocation: SourceLocation = #_sourceLocation) -> [SessionEffect] {
        send(.capture(id, .started), sourceLocation: sourceLocation)
    }

    @discardableResult
    mutating func ended(_ id: DictationID, audio: TimeInterval = 2,
                        sourceLocation: SourceLocation = #_sourceLocation) -> [SessionEffect] {
        send(.capture(id, .ended(CaptureSummary(duration: audio))), sourceLocation: sourceLocation)
    }

    @discardableResult
    mutating func transcript(_ id: DictationID, _ text: String,
                             sourceLocation: SourceLocation = #_sourceLocation) -> [SessionEffect] {
        send(.transcript(id, .success(SpeechResult(text: text))), sourceLocation: sourceLocation)
    }

    @discardableResult
    mutating func insertion(_ id: DictationID, _ outcome: InsertionOutcome, text: String, heard: String? = nil,
                            pressEnter: Bool = false,
                            sourceLocation: SourceLocation = #_sourceLocation) -> [SessionEffect] {
        let processed = ProcessedDictation(heard: heard ?? text, text: text, pressEnter: pressEnter)
        return send(.insertion(id, InsertionReport(outcome: outcome, processed: processed)),
                    sourceLocation: sourceLocation)
    }

    /// A Hold to Talk dictation from press to the start of transcription. Returns its id.
    @discardableResult
    mutating func recordHold(at time: TimeInterval, for length: TimeInterval = 2,
                             sourceLocation: SourceLocation = #_sourceLocation) -> DictationID {
        guard let id = press(.hold, at: time, sourceLocation: sourceLocation) else {
            Issue.record("the press started nothing", sourceLocation: sourceLocation)
            return DictationID(0)
        }
        started(id, sourceLocation: sourceLocation)
        release(at: time + length, sourceLocation: sourceLocation)
        ended(id, audio: length, sourceLocation: sourceLocation)
        return id
    }

    /// A whole dictation, inserted. Returns its id.
    @discardableResult
    mutating func dictate(_ text: String, at time: TimeInterval,
                          sourceLocation: SourceLocation = #_sourceLocation) -> DictationID {
        let id = recordHold(at: time, sourceLocation: sourceLocation)
        transcript(id, text, sourceLocation: sourceLocation)
        insertion(id, .inserted, text: text, sourceLocation: sourceLocation)
        return id
    }

    /// Fires the timer if it is armed, as the runtime would.
    @discardableResult
    mutating func fire(_ timer: TimerID, sourceLocation: SourceLocation = #_sourceLocation) -> [SessionEffect] {
        send(.timer(timer), sourceLocation: sourceLocation)
    }

    /// Asserts that the session has nothing in flight: no capture or stream open, no dictation left, the output
    /// free and no capture timer armed. A notice may still be showing.
    func expectSettled(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(state.capture == .idle, "no capture", sourceLocation: sourceLocation)
        #expect(state.dictationCount == 0, "no dictation left", sourceLocation: sourceLocation)
        #expect(state.output == .free, "output free", sourceLocation: sourceLocation)
        #expect(ledger.openCaptures.isEmpty, "every capture released: \(ledger.openCaptures)",
                sourceLocation: sourceLocation)
        #expect(ledger.openStreams.isEmpty, "every stream finished or cancelled: \(ledger.openStreams)",
                sourceLocation: sourceLocation)
        #expect(ledger.armed.allSatisfy { if case .notice = $0 { true } else { false } },
                "no capture timer armed: \(ledger.armed)", sourceLocation: sourceLocation)
        #expect(ledger.begun == ledger.completed, "every dictation completed once", sourceLocation: sourceLocation)
    }
}

/// Bookkeeping over the effects and the events that answer them, with the invariant checks of section 3.
struct Ledger {
    /// Dictations that were asked to start a capture.
    var begun: Set<DictationID> = []
    var completed: Set<DictationID> = []
    /// Captures that have not ended and were not discarded.
    var openCaptures: Set<DictationID> = []
    /// Captures the session still wants running: started, and not yet stopped, aborted or discarded.
    var runningCaptures: Set<DictationID> = []
    var stopped: Set<DictationID> = []
    var aborted: Set<DictationID> = []
    /// Streams opened and neither finished (with a transcript delivered) nor cancelled.
    var openStreams: Set<DictationID> = []
    var finishing: Set<DictationID> = []
    var inserted: Set<DictationID> = []
    var armed: Set<TimerID> = []
    var everArmed: Set<TimerID> = []
    var fired: Set<TimerID> = []

    mutating func check(before: SessionState, event: SessionEvent, after: SessionState, effects: [SessionEffect],
                        sourceLocation: SourceLocation) {
        func fail(_ message: String) {
            Issue.record("\(message) (after \(event))", sourceLocation: sourceLocation)
        }

        // A stale event is dropped whole: no effect and no change.
        if isStale(event, in: before) {
            if !effects.isEmpty || after != before { fail("a stale event changed something") }
        }

        // What the event itself tells the bookkeeping.
        switch event {
        case .capture(let id, .ended):
            openCaptures.remove(id)
        case .transcript(let id, _) where finishing.contains(id) && before.holds(id):
            openStreams.remove(id)
            finishing.remove(id)
        case .timer(let timer) where armed.contains(timer):
            armed.remove(timer)
            fired.insert(timer)
        default:
            break
        }

        let mentionable = Set(before.dictationIDs).union(after.dictationIDs)
        for effect in effects {
            if let id = effect.dictation, !mentionable.contains(id) {
                fail("\(effect) names a dictation the state neither held nor holds")
            }
            switch effect {
            case .startCapture(let id, _):
                if begun.contains(id) { fail("\(id) started twice") }
                if !runningCaptures.isEmpty { fail("\(id) started while \(runningCaptures) still runs") }
                begun.insert(id)
                openCaptures.insert(id)
                runningCaptures.insert(id)
            case .openStream(let id, _):
                openStreams.insert(id)
            case .stopCapture(let id):
                if stopped.contains(id) { fail("\(id) stopped twice") }
                stopped.insert(id)
                runningCaptures.remove(id)
            case .abortCapture(let id):
                if aborted.contains(id) || !stopped.contains(id) { fail("\(id) aborted twice or before its stop") }
                aborted.insert(id)
            case .finishStream(let id):
                if finishing.contains(id) { fail("\(id) finished twice") }
                finishing.insert(id)
            case .discard(let id):
                if after.holds(id) { fail("\(id) discarded but still held") }
                openCaptures.remove(id)
                runningCaptures.remove(id)
                openStreams.remove(id)
                finishing.remove(id)
            case .insert(let request):
                if inserted.contains(request.id) { fail("\(request.id) inserted twice") }
                inserted.insert(request.id)
            case .setTimer(let timer, _):
                if everArmed.contains(timer) { fail("\(timer) armed twice") }
                everArmed.insert(timer)
                armed.insert(timer)
            case .cancelTimer(let timer):
                if !armed.contains(timer) { fail("\(timer) cancelled but not armed (fired: \(fired.contains(timer)))") }
                armed.remove(timer)
            case .complete(let completion):
                if completed.contains(completion.id) { fail("\(completion.id) completed twice") }
                if after.holds(completion.id) { fail("\(completion.id) completed but still held") }
                completed.insert(completion.id)
            case .requestMicrophoneAccess, .reinsert, .record:
                break
            }
        }

        // Every dictation that left the session in this step completed in this step.
        for id in before.dictationIDs where !after.holds(id) && !completed.contains(id) {
            fail("\(id) left without a completion")
        }
        // A dictation that leaves the microphone slot was stopped or discarded.
        if let live = before.capture.live, after.capture.live?.id != live.id,
           !stopped.contains(live.id), !effects.contains(.discard(live.id)) {
            fail("\(live.id) left the microphone without a stop or a discard")
        }

        // The structure of the state.
        if after.dictationCount > Session.maximumDictations { fail("more than three dictations") }
        let ids = after.dictationIDs
        if ids != ids.sorted() || Set(ids).count != ids.count { fail("dictations out of order: \(ids)") }
        if runningCaptures.count > 1 { fail("more than one capture wanted at once: \(runningCaptures)") }
        // The timers the state considers armed are exactly the ones armed and neither fired nor cancelled.
        let derived = Set(after.derivedTimers)
        if derived != armed { fail("armed timers \(armed) but the state implies \(derived)") }
    }

    func isStale(_ event: SessionEvent, in state: SessionState) -> Bool {
        switch event {
        case .capture(let id, _), .transcript(let id, _), .insertion(let id, _): !state.holds(id)
        case .timer(let timer): !state.isArmed(timer)
        case .reinsertion(let replay, _): state.output != .replaying(replay)
        default: false
        }
    }
}

extension SessionState {
    /// Every timer the state's phases imply is armed.
    var derivedTimers: [TimerID] {
        var timers: [TimerID] = []
        let candidates = dictationIDs.flatMap { [TimerID.captureStart($0), .captureLimit($0), .captureDrain($0)] }
            + (notice.map { [TimerID.notice($0.id)] } ?? [])
        for timer in candidates where isArmed(timer) { timers.append(timer) }
        return timers
    }
}

extension SessionEffect {
    /// The dictation the effect concerns, if it concerns one.
    var dictation: DictationID? {
        switch self {
        case .startCapture(let id, _), .openStream(let id, _), .stopCapture(let id), .abortCapture(let id),
             .finishStream(let id), .discard(let id):
            id
        case .insert(let request):
            request.id
        case .record(let entry):
            entry.dictation
        case .complete(let completion):
            completion.id
        case .setTimer(let timer, _), .cancelTimer(let timer):
            timer.dictation
        case .requestMicrophoneAccess, .reinsert:
            nil
        }
    }
}

extension TimerID {
    var dictation: DictationID? {
        switch self {
        case .captureStart(let id), .captureDrain(let id), .captureLimit(let id): id
        case .notice: nil
        }
    }
}

extension Array where Element == SessionEffect {
    /// The dictation a `startCapture` in these effects started.
    var startedDictation: DictationID? {
        for effect in self { if case .startCapture(let id, _) = effect { return id } }
        return nil
    }

    /// The notice timers these effects arm, which is how a test sees that a notice was shown.
    var shownNotices: Int {
        filter { if case .setTimer(.notice, _) = $0 { true } else { false } }.count
    }

    var discarded: [DictationID] {
        compactMap { if case .discard(let id) = $0 { id } else { nil } }
    }

    var completions: [DictationCompletion] {
        compactMap { if case .complete(let completion) = $0 { completion } else { nil } }
    }

    var records: [RunLogEntry] {
        compactMap { if case .record(let entry) = $0 { entry } else { nil } }
    }

    var inserts: [InsertionRequest] {
        compactMap { if case .insert(let request) = $0 { request } else { nil } }
    }
}

let id1 = DictationID(1)
let id2 = DictationID(2)
let id3 = DictationID(3)
let id4 = DictationID(4)

/// A pipeline item as a test names it.
struct Stage: Equatable, CustomStringConvertible {
    var id: DictationID
    var phase: PipelineItem.Phase

    init(_ id: DictationID, _ phase: PipelineItem.Phase) {
        self.id = id
        self.phase = phase
    }

    var description: String { "\(id) \(phase)" }
}

extension SessionState {
    var stages: [Stage] { pipeline.map { Stage($0.id, $0.phase) } }
}
