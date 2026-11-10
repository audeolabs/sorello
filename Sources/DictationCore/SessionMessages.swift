import Foundation

// What goes into `Session.reduce` and what comes out (ARCHITECTURE.md, section 3, "Events" and "Effects").

// MARK: - Events

/// Something that happened, reported to the session. Every event that concerns one dictation names it, so an event
/// for a dictation the session no longer holds is recognised and dropped in one place.
public enum SessionEvent: Sendable, Equatable {
    /// A trigger, with the monotonic time it arrived on `SessionClock`'s timeline.
    case trigger(TriggerEvent, at: TimeInterval)
    /// What a dictation's capture reported.
    case capture(DictationID, CaptureReport)
    /// The dictation's stream finished.
    case transcript(DictationID, Result<SpeechResult, SpeechFailure>)
    /// The dictation's insertion transaction ended.
    case insertion(DictationID, InsertionReport)
    /// A Paste Again ended.
    case reinsertion(ReplayID, InsertionOutcome)
    /// A timer fired.
    case timer(TimerID)
    /// The microphone permission, as a request answered it or as it was read.
    case microphoneAccess(MicrophoneAccess)
    /// The engine's readiness changed.
    case engine(EngineReadiness)
    /// The Run Log was cleared, so the session forgets the text Paste Again would insert.
    case forgetLast
}

/// What a capture reports to the session about itself. The audio never comes this way: chunks go straight from
/// the capture to the speech stream, the level sink and the recording kept for the Run Log.
public enum CaptureReport: Sendable, Equatable {
    /// The microphone is running.
    case started
    /// The capture could not start, or broke.
    case failed(CaptureFailure)
    /// No audio arrived for 2 s.
    case stalled
    /// The device went away or the system took the audio session.
    case interrupted(CaptureInterruption)
    /// Every chunk the capture delivered has been appended. Sent exactly once, last.
    case ended(CaptureSummary)
}

/// What a capture amounted to, once it has ended.
public struct CaptureSummary: Sendable, Equatable {
    /// Seconds of audio delivered.
    public var duration: TimeInterval

    public init(duration: TimeInterval) { self.duration = duration }

    /// The summary of a recording of `sampleCount` samples at `AudioFormat.sampleRate`.
    public init(sampleCount: Int) { duration = Double(sampleCount) / AudioFormat.sampleRate }
}

/// How an insertion transaction ended, and what composition produced if it ran.
public struct InsertionReport: Sendable, Equatable {
    public var outcome: InsertionOutcome
    /// The dictation after the text rules. Nil when the transaction ended before it asked for the text.
    public var processed: ProcessedDictation?

    public init(outcome: InsertionOutcome, processed: ProcessedDictation?) {
        self.outcome = outcome
        self.processed = processed
    }
}

// MARK: - Effects

/// Work the session asks the runtime to do. Effects are values, so a test reads exactly what the session decided.
public enum SessionEffect: Sendable, Equatable {
    /// Show the microphone permission prompt and report the answer as `microphoneAccess`.
    case requestMicrophoneAccess
    /// Start the microphone for this dictation. The runtime also reads the app in front and the text rules now;
    /// they stay with the dictation.
    case startCapture(DictationID, CaptureRequest)
    /// Open this dictation's speech stream.
    case openStream(DictationID, retainForCorrection: Bool)
    /// Finish the capture and deliver what was heard.
    case stopCapture(DictationID)
    /// Stop producing audio now. What was already delivered still counts, and `capture.ended` follows as usual.
    case abortCapture(DictationID)
    /// End the stream's audio and report the transcript.
    case finishStream(DictationID)
    /// Throw the dictation away: cancel its task, release its capture and stream, drop its audio. Nothing of it is
    /// transcribed or inserted.
    case discard(DictationID)
    /// Run one insertion transaction for this dictation, composing its text when the destination is known.
    case insert(InsertionRequest)
    /// Paste this text again, verbatim, never pressing Return.
    case reinsert(ReplayID, text: String, restoreClipboard: Bool)
    /// Arm this timer; it reports `timer` when it fires.
    case setTimer(TimerID, after: TimeInterval)
    /// Disarm this timer. A fired timer is never cancelled, and a cancelled one never fires.
    case cancelTimer(TimerID)
    /// Save a Run Log entry with the dictation's audio.
    case record(RunLogEntry)
    /// The dictation has left the session: tell the app how it ended.
    case complete(DictationCompletion)
}

/// What an insertion needs to know about its dictation.
public struct InsertionRequest: Sendable, Equatable {
    public var id: DictationID
    /// The transcript the text rules run on.
    public var speech: SpeechResult
    public var style: DictationStyle
    public var restoreClipboard: Bool

    public init(id: DictationID, speech: SpeechResult, style: DictationStyle, restoreClipboard: Bool) {
        self.id = id
        self.speech = speech
        self.style = style
        self.restoreClipboard = restoreClipboard
    }
}

/// A Run Log entry as the session decides it. The runtime adds the date and the dictation's recording.
public struct RunLogEntry: Sendable, Equatable {
    public var dictation: DictationID
    /// The recognizer's transcript; empty when transcription failed.
    public var heard: String
    /// What was inserted, or would have been; empty when transcription failed.
    public var text: String
    public var outcome: DictationOutcome

    public init(dictation: DictationID, heard: String, text: String, outcome: DictationOutcome) {
        self.dictation = dictation
        self.heard = heard
        self.text = text
        self.outcome = outcome
    }
}

/// How a dictation left the session, reported once to the app (for the correction watch and the engine's retained
/// audio, which follow the dictation's fate).
public struct DictationCompletion: Sendable, Equatable {
    public var id: DictationID
    public var ending: DictationEnding
    /// The transcript, if the stream finished with one.
    public var speech: SpeechResult?
    /// The dictation after the text rules, if composition ran.
    public var processed: ProcessedDictation?

    public init(id: DictationID, ending: DictationEnding, speech: SpeechResult? = nil,
                processed: ProcessedDictation? = nil) {
        self.id = id
        self.ending = ending
        self.speech = speech
        self.processed = processed
    }
}

/// How a dictation ended.
public enum DictationEnding: Sendable, Equatable {
    /// Thrown away before it produced a transcript: cancelled, abandoned, a tap, too little audio, interrupted
    /// while starting, or the microphone did not start.
    case discarded
    /// The transcript was empty.
    case nothingHeard
    case transcriptionFailed(SpeechFailure)
    /// The insertion transaction ran and ended this way.
    case insertion(InsertionOutcome)
}

/// What a trigger did, for `TriggerHandling.handle`.
public struct TriggerOutcome: Sendable, Equatable {
    public var effects: [SessionEffect]
    /// Whether the trigger acted. For Escape and the pill's cancel button this is true only if something was
    /// cancelled, which is when the shortcut adapter consumes the key.
    public var acted: Bool

    public init(effects: [SessionEffect], acted: Bool) {
        self.effects = effects
        self.acted = acted
    }
}
