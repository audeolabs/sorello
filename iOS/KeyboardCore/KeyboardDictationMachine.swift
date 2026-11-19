#if SORELLO_KEYBOARD_DICTATION
import Foundation

/// The in-keyboard dictation's timings (ARCHITECTURE.md, "In-keyboard dictation (experiment)").
enum KeyboardDictationTiming {
    /// No audio within this of the tap, while starting: the tap goes on as a host tap.
    static let startupTimeout: TimeInterval = 5
    /// After the first audio, no well-formed chunk for this while capture is open: `captureLost`.
    static let audioGap: TimeInterval = 2
    /// No text within this of the stop: `transcriptionFailed`.
    static let finishTimeout: TimeInterval = 120
    /// Accepted audio that may wait in Swift unconverted; more is `captureLost`.
    static let maxQueuedAudio: TimeInterval = 2
    /// The longest chunk the page may post.
    static let maxChunkDuration: TimeInterval = 0.25
    /// While recording, the record is rewritten between steps at most this often, when its memory figures changed.
    static let recordInterval: TimeInterval = 1
}

/// When the record is rewritten between steps while recording: at most once per `recordInterval`, and only when its
/// memory figures (the least memory left, the warnings) changed since it was last written. A step's write counts.
struct KeyboardDictationRecordSchedule: Equatable, Sendable {
    private var lastWrite: TimeInterval?
    private var changed = false

    /// The figures changed.
    mutating func figuresChanged() { changed = true }

    /// Whether to write now; if so, the write is counted.
    mutating func isDue(at now: TimeInterval) -> Bool {
        guard changed, lastWrite.map({ now - $0 >= KeyboardDictationTiming.recordInterval || now < $0 }) ?? true else { return false }
        wrote(at: now)
        return true
    }

    /// The record was written (a step): the figures it holds are current.
    mutating func wrote(at now: TimeInterval) {
        lastWrite = now
        changed = false
    }
}

/// One in-keyboard dictation at a time, as a state machine fed events with a monotonic clock (ARCHITECTURE.md,
/// "In-keyboard dictation (experiment)", Phases, Binding). Pure: it returns the effects for the keyboard to carry out,
/// in order. Each attempt has an in-memory id, and an event for an attempt that has ended has no effect, so nothing an
/// ended attempt started can capture, insert or write the record. The text it holds is in memory only, at most
/// `resultTTL` after it was made, and never past the keyboard hiding.
struct KeyboardDictationMachine: Sendable {
    /// Seconds on a monotonic clock.
    typealias Instant = TimeInterval

    enum Phase: Equatable, Sendable { case idle, starting, recording, transcribing }

    enum Event: Equatable, Sendable {
        /// The user's mic tap that the route sent here, in the field `documentID` (nil: no field identity).
        case tap(attempt: UUID, documentID: UUID?)
        /// A well-formed chunk was accepted, with its level.
        case audio(attempt: UUID, level: Float)
        /// Capture failed (the web view could not capture, a track ended by itself, a malformed chunk, an overflow).
        case captureFailed(attempt: UUID)
        case modelLoading(attempt: UUID)
        case modelReady(attempt: UUID)
        case modelFailed(attempt: UUID)
        case firstChunkDecoded(attempt: UUID)
        /// The processed text (`DictationRules`), as a result named by the attempt.
        case transcribed(attempt: UUID, result: DictationResult)
        case transcriptionFailed(attempt: UUID)
        /// Stop, on the attempt the bar showed.
        case stop(attempt: UUID)
        /// Cancel, on the attempt the bar showed.
        case cancel(attempt: UUID)
        /// The keyboard is hiding.
        case hide
        /// A status the keyboard read shows the host owning the microphone.
        case hostOwnsMicrophone
        /// `documentIdentifier` may have changed.
        case focus(documentID: UUID?)
        /// The clock moved; timeouts and expiries are judged.
        case tick
    }

    enum Effect: Equatable, Sendable {
        /// Make the web view and ask for audio.
        case openCapture(UUID)
        /// Load the engine, or use the loaded one, and stream once it is ready.
        case loadModel(UUID)
        /// Stop: close capture at once and seal the recording, then finish the transcription against it.
        case seal(UUID)
        /// Every end: capture torn down, the recording dropped, the transcription cancelled.
        case tearDown(UUID)
        /// A step for the record of this attempt.
        case step(KeyboardDictationRecord.Step, UUID)
        /// The record's outcome (the step `ended`).
        case outcome(KeyboardDictationRecord.Outcome, UUID)
        /// Nothing was heard: go on as a host tap would, if the keyboard still shows the tap's field `documentID`.
        case handToHost(documentID: UUID)
        /// "No speech detected".
        case noSpeech
    }

    /// A text made in the keyboard, waiting to be inserted (bound) or offered by the chip (unbound).
    struct Waiting: Equatable, Sendable {
        var result: DictationResult
        /// The field it is bound to, while the binding holds; nil once it is offered.
        var boundTo: UUID?
        var madeAt: Instant

        var bound: Bool { boundTo != nil }
    }

    private struct Attempt: Equatable, Sendable {
        var id: UUID
        var phase: Phase
        var tappedAt: Instant
        /// The field the tap was made in, while the binding holds.
        var boundTo: UUID?
        var recordingStartedAt: Instant?
        var lastAudioAt: Instant?
        var stoppedAt: Instant?
        var level: Float = 0
    }

    private var attempt: Attempt?
    /// The texts made, oldest first, each until it is taken, `resultTTL` after it was made, or the keyboard hides.
    private(set) var waiting: [Waiting] = []
    /// A failure the bar shows, until `KeyboardPresenter.errorDisplayDuration` after it.
    private var shown: (code: HostErrorCode, until: Instant)?
    /// This instance's last in-keyboard dictation ended with `captureUnavailable` (the route's sticky condition).
    private(set) var lastEndedCaptureUnavailable = false

    var phase: Phase { attempt?.phase ?? .idle }
    var isRunning: Bool { attempt != nil }
    /// The running attempt's id: Stop and Cancel act on it.
    var runningAttemptID: UUID? { attempt?.id }
    /// Capture is open only while starting and recording.
    var isCaptureOpen: Bool { phase == .starting || phase == .recording }

    /// Feeds one event at `now`; returns what to do, in order. The clock is judged first, so an event that comes after a
    /// deadline whose timer has not fired yet finds the attempt already ended.
    mutating func handle(_ event: Event, at now: Instant) -> [Effect] {
        let expired = judgeTime(at: now)
        guard event != .tick else { return expired }
        return expired + process(event, at: now)
    }

    private mutating func process(_ event: Event, at now: Instant) -> [Effect] {
        switch event {
        case let .tap(id, documentID):
            guard attempt == nil else { return [] }
            attempt = Attempt(id: id, phase: .starting, tappedAt: now, boundTo: documentID)
            shown = nil
            return [.step(.tapped, id), .openCapture(id), .step(.captureRequested, id), .loadModel(id)]

        case let .audio(id, level):
            guard var current = running(id), current.phase == .starting || current.phase == .recording else { return [] }
            current.level = level.isFinite ? min(max(level, 0), 1) : 0
            current.lastAudioAt = now
            var effects: [Effect] = []
            if current.phase == .starting {
                current.phase = .recording
                current.recordingStartedAt = now
                effects.append(.step(.firstAudio, id))
            }
            attempt = current
            return effects

        case let .captureFailed(id):
            guard let current = running(id) else { return [] }
            switch current.phase {
            case .starting: return end(with: .captureUnavailable, at: now)
            case .recording: return end(with: .captureLost, at: now)
            case .idle, .transcribing: return []
            }

        case let .modelLoading(id):
            return running(id) == nil ? [] : [.step(.modelLoading, id)]
        case let .modelReady(id):
            return running(id) == nil ? [] : [.step(.modelReady, id)]
        case let .firstChunkDecoded(id):
            return running(id) == nil ? [] : [.step(.firstChunkDecoded, id)]
        case let .modelFailed(id):
            return running(id) == nil ? [] : end(with: .modelFailed, at: now)
        case let .transcriptionFailed(id):
            guard running(id)?.phase == .transcribing else { return [] }
            return end(with: .transcriptionFailed, at: now)

        case let .transcribed(id, result):
            guard let current = running(id), current.phase == .transcribing else { return [] }
            attempt = nil
            lastEndedCaptureUnavailable = false
            guard !KeyboardResultLedger.insertsNothing(result) else {
                return [.step(.transcribed, id), .outcome(.noSpeech, id), .noSpeech]
            }
            waiting.append(Waiting(result: result, boundTo: current.boundTo, madeAt: now))
            return [.step(.transcribed, id), .outcome(.text, id)] + (current.boundTo == nil ? [.step(.offered, id)] : [])

        case let .stop(id):
            guard var current = running(id) else { return [] }
            switch current.phase {
            case .starting:
                // Nothing was heard.
                return end(cancelled: current.id)
            case .recording:
                current.phase = .transcribing
                current.stoppedAt = now
                attempt = current
                return [.seal(id), .step(.stopped, id)]
            case .idle, .transcribing:
                return []
            }

        case let .cancel(id):
            return running(id) == nil ? [] : end(cancelled: id)

        case .hide:
            var effects: [Effect] = []
            if attempt != nil { effects += end(with: .keyboardDismissed, at: now) }
            effects += drop { _ in true }
            shown = nil
            return effects

        case .hostOwnsMicrophone:
            return attempt == nil ? [] : end(with: .hostTookOver, at: now)

        case let .focus(documentID):
            // A focus change ends the binding for good, even if focus comes back.
            if let bound = attempt?.boundTo, bound != documentID { attempt?.boundTo = nil }
            var effects: [Effect] = []
            for index in waiting.indices {
                guard let bound = waiting[index].boundTo, bound != documentID else { continue }
                waiting[index].boundTo = nil
                effects.append(.step(.offered, waiting[index].result.requestID))
            }
            return effects

        case .tick:
            return []
        }
    }

    /// The oldest bound text, for insertion now (the editing side is not busy): taken at most once, and only before
    /// `resultTTL` has passed. Nil when there is none.
    mutating func takeBoundText(at now: Instant) -> DictationResult? {
        guard let index = waiting.firstIndex(where: { $0.bound && Self.isFresh($0, at: now) }) else { return nil }
        return waiting.remove(at: index).result
    }

    /// The chip's text, if `attemptID` is the one it showed and it still waits unbound and fresh: taken at most once.
    mutating func takeOfferedText(_ attemptID: UUID, at now: Instant) -> DictationResult? {
        guard let index = waiting.firstIndex(where: { !$0.bound && $0.result.requestID == attemptID && Self.isFresh($0, at: now) })
        else { return nil }
        return waiting.remove(at: index).result
    }

    /// Drops the text of `attemptID`, if it still waits; its step `dropped`.
    mutating func dropText(_ attemptID: UUID) -> [Effect] {
        drop { $0.result.requestID == attemptID }
    }

    /// The newest unbound text the chip may offer.
    var offeredText: DictationResult? { waiting.last { !$0.bound }?.result }

    /// The oldest bound text waiting for the editing side.
    var boundText: DictationResult? { waiting.first { $0.bound }?.result }

    /// The mode the top row shows for the attempt, or for a failure it shows; nil when the host's mode applies.
    /// `wallNow` dates the recording's start as the host's mode does.
    func mode(at now: Instant, wallNow: Date) -> KeyboardMode? {
        if let attempt {
            switch attempt.phase {
            case .starting: return .starting
            case .recording:
                let elapsed = now - (attempt.recordingStartedAt ?? now)
                return .recording(level: attempt.level, startedAt: wallNow.addingTimeInterval(-max(elapsed, 0)))
            case .transcribing: return .transcribing
            case .idle: return nil
            }
        }
        if let shown, now < shown.until { return .error(shown.code) }
        return nil
    }

    /// When the next timeout or expiry falls, for a timer; nil when nothing waits on the clock.
    var nextDeadline: Instant? {
        var deadlines: [Instant] = []
        if let attempt {
            switch attempt.phase {
            case .starting: deadlines.append(attempt.tappedAt + KeyboardDictationTiming.startupTimeout)
            case .recording:
                if let last = attempt.lastAudioAt { deadlines.append(last + KeyboardDictationTiming.audioGap) }
                if let start = attempt.recordingStartedAt { deadlines.append(start + DictationProtocol.maxDictationDuration) }
            case .transcribing:
                if let stopped = attempt.stoppedAt { deadlines.append(stopped + KeyboardDictationTiming.finishTimeout) }
            case .idle: break
            }
        }
        if let oldest = waiting.first { deadlines.append(oldest.madeAt + DictationProtocol.resultTTL) }
        if let shown { deadlines.append(shown.until) }
        return deadlines.min()
    }

    // MARK: Private

    private func running(_ id: UUID) -> Attempt? {
        attempt?.id == id ? attempt : nil
    }

    private mutating func judgeTime(at now: Instant) -> [Effect] {
        var effects: [Effect] = []
        if let current = attempt {
            switch current.phase {
            case .starting:
                if now - current.tappedAt >= KeyboardDictationTiming.startupTimeout {
                    effects += end(with: .startupTimeout, at: now)
                }
            case .recording:
                if let last = current.lastAudioAt, now - last >= KeyboardDictationTiming.audioGap {
                    effects += end(with: .captureLost, at: now)
                } else if let start = current.recordingStartedAt, now - start >= DictationProtocol.maxDictationDuration {
                    effects += process(.stop(attempt: current.id), at: now)
                }
            case .transcribing:
                if let stopped = current.stoppedAt, now - stopped >= KeyboardDictationTiming.finishTimeout {
                    effects += end(with: .transcriptionFailed, at: now)
                }
            case .idle:
                break
            }
        }
        effects += drop { !Self.isFresh($0, at: now) }
        if let current = shown, now >= current.until { shown = nil }
        return effects
    }

    /// Every end marks the attempt ended first, then tears down and writes the outcome, and only then falls back.
    private mutating func end(with failure: KeyboardDictationFailure, at now: Instant) -> [Effect] {
        guard let current = attempt else { return [] }
        attempt = nil
        lastEndedCaptureUnavailable = failure == .captureUnavailable
        if let code = failure.shownError { shown = (code, now + KeyboardPresenter.errorDisplayDuration) }
        var effects: [Effect] = [.tearDown(current.id), .outcome(KeyboardDictationRecord.Outcome(failure), current.id)]
        if failure.fallsBackToHost, let field = current.boundTo { effects.append(.handToHost(documentID: field)) }
        return effects
    }

    private mutating func end(cancelled id: UUID) -> [Effect] {
        attempt = nil
        lastEndedCaptureUnavailable = false
        return [.tearDown(id), .outcome(.cancelled, id)]
    }

    private mutating func drop(where matches: (Waiting) -> Bool) -> [Effect] {
        let dropped = waiting.filter(matches)
        waiting.removeAll(where: matches)
        return dropped.map { .step(.dropped, $0.result.requestID) }
    }

    private static func isFresh(_ text: Waiting, at now: Instant) -> Bool {
        now - text.madeAt < DictationProtocol.resultTTL
    }
}
#endif
