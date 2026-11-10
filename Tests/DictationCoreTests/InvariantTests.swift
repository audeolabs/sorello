import DictationCore
import Foundation
import Testing

/// Long random event sequences, seeded so a failure can be replayed. `Machine` checks section 3's invariants after
/// every step (see `Ledger.check`): at most one capture wanted at once, at most three dictations, ids in order, every
/// effect about a dictation the state holds or just released, every stop and abort at most once, no dictation
/// inserted twice, every timer armed once and then either cancelled or fired, never both, every dictation completed
/// exactly once, and stale events changing nothing. Each sequence then settles and must leave nothing in flight.
@Suite("Invariants")
struct InvariantTests {
    /// Each sequence starts with one double-tap setting and switches it now and then, as a user might.
    @Test(arguments: DoubleTapAction.allCases, 0..<120)
    func randomSequencesKeepTheInvariants(doubleTap: DoubleTapAction, seed: UInt64) {
        var random = SplitMix64(seed: seed)
        var machine = Machine(microphone: random.pick([.granted, .granted, .unknown, .denied]),
                              engine: random.pick([.ready, .ready, .preparing]),
                              settings: SessionSettings(doubleTap: doubleTap))
        var time: TimeInterval = 100
        var replays: [ReplayID] = []
        for _ in 0..<400 {
            time += random.chance(0.4) ? random.uniform(0.01, 0.35) : random.uniform(0.3, 3)
            if random.chance(0.03) { machine.settings.doubleTap = random.pick(DoubleTapAction.allCases) }
            let effects = machine.send(nextEvent(&random, machine.state, time: time, replays: replays))
            for case .reinsert(let replay, _, _) in effects { replays.append(replay) }
        }
        settle(&machine, time: time)
        machine.expectSettled()
    }

    private func nextEvent(_ random: inout SplitMix64, _ state: SessionState, time: TimeInterval,
                           replays: [ReplayID]) -> SessionEvent {
        let held = state.dictationIDs
        // Mostly the dictations the state holds, sometimes one it let go of or never had.
        func someID() -> DictationID {
            if !held.isEmpty && random.chance(0.85) { return random.pick(held) }
            return DictationID(UInt64(random.below(8)) + 1)
        }
        // Hold to Talk pressed, released and abandoned during toggle recordings, which it can stop (rule 5).
        if state.capture.live?.mode == .toggle, random.chance(0.25) {
            return .trigger(random.pick([.holdPressed, .holdReleased(.keyUp), .holdReleased(.keyUp),
                                         .holdReleased(.interrupted), .holdAbandoned]), at: time)
        }
        switch random.below(100) {
        case 0..<34:
            return .trigger(random.pick([.holdPressed, .holdPressed, .holdReleased(.keyUp), .holdReleased(.keyUp),
                                         .holdReleased(.interrupted), .holdAbandoned, .togglePressed, .togglePressed,
                                         .cancelPressed, .pasteAgainPressed, .pillStopClicked, .pillCancelClicked,
                                         .systemInterrupted]), at: time)
        case 34..<54:
            let report = random.pick([CaptureReport.started, .started, .stalled, .interrupted(.deviceRemoved),
                                      .failed(.failed), .ended(CaptureSummary(duration: random.uniform(0, 0.3))),
                                      .ended(CaptureSummary(duration: random.uniform(0.1, 30)))])
            return .capture(state.capture.live.map { random.chance(0.6) ? $0.id : someID() } ?? someID(), report)
        case 54..<66:
            let result: Result<SpeechResult, SpeechFailure> = random.chance(0.15)
                ? .failure(random.pick([.failed, .cancelled, .engineUnavailable(.loadFailed)]))
                : .success(SpeechResult(text: random.pick(["", " ", "Invented words", "press enter"])))
            return .transcript(someID(), result)
        case 66..<76:
            let outcome = random.pick([InsertionOutcome.inserted, .inserted, .nothingToInsert,
                                       .leftOnClipboard(.targetChanged), .failed(.eventPostFailed),
                                       .failed(.commandNotPosted)])
            let processed = random.chance(0.9)
                ? ProcessedDictation(heard: "Invented words", text: random.pick(["", "Invented words."])) : nil
            return .insertion(someID(), InsertionReport(outcome: outcome, processed: processed))
        case 76..<80:
            let replay = replays.isEmpty ? ReplayID(1) : random.pick(replays)
            return .reinsertion(replay, random.pick([.inserted, .failed(.cancelled)]))
        case 80..<93:
            let armed = state.derivedTimers
            if !armed.isEmpty && random.chance(0.8) { return .timer(random.pick(armed)) }
            return .timer(random.pick([.captureStart(someID()), .captureDrain(someID()), .captureLimit(someID()),
                                       .notice(NoticeID(UInt64(random.below(6)) + 1))]))
        case 93..<96:
            return .microphoneAccess(random.pick([.granted, .granted, .denied, .unknown]))
        case 96..<99:
            return .engine(random.pick([.ready, .ready, .preparing, .failed(.loadFailed)]))
        default:
            return .forgetLast
        }
    }

    /// Drives every dictation to its end the ordinary way: starts start, recordings stop, captures end, streams
    /// finish and insertions report.
    private func settle(_ machine: inout Machine, time: TimeInterval) {
        var time = time
        for _ in 0..<60 {
            time += 1
            let state = machine.state
            if case .awaitingPermission = state.capture {
                machine.send(.microphoneAccess(.granted))
            } else if case .starting(let live, _) = state.capture {
                machine.started(live.id)
            } else if state.capture.live != nil {
                machine.trigger(.systemInterrupted, at: time)
            } else if let item = state.pipeline.first(where: { $0.phase == .draining(drainTimerArmed: true)
                                                               || $0.phase == .draining(drainTimerArmed: false) }) {
                machine.ended(item.id, audio: 1)
            } else if let item = state.pipeline.first(where: { if case .transcribing = $0.phase { true } else { false } }) {
                machine.transcript(item.id, "Invented words")
            } else if case .inserting(let item) = state.output {
                machine.insertion(item.id, .inserted, text: "Invented words.")
            } else if case .replaying(let replay) = state.output {
                machine.send(.reinsertion(replay, .inserted))
            } else {
                return
            }
        }
        Issue.record("the session did not settle")
    }
}

/// A small, fast, seedable generator, so a failing sequence can be replayed from its seed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }

    mutating func chance(_ probability: Double) -> Bool { uniform(0, 1) < probability }

    mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * Double(next() >> 11) / Double(1 << 53)
    }

    mutating func pick<Element>(_ elements: [Element]) -> Element { elements[below(elements.count)] }
}
