import Foundation

// The value that holds all dictation state (ARCHITECTURE.md, section 3, "State"). Only `Session.reduce` changes it,
// so every field can be read anywhere but set only inside this module.

// MARK: - Numbers

/// The session's fixed times, in seconds, as section 3 gives them. Kept in one place so a test can name the
/// boundary it checks instead of repeating a literal.
public enum SessionTiming {
    /// How long a capture may take to start, including any wait for the previous capture's teardown (rule 1).
    public static let captureStart: TimeInterval = 3
    /// How long a stopped capture may take to deliver its last audio before it is aborted (rule 4).
    public static let captureDrain: TimeInterval = 2
    /// The longest recording (rule 3).
    public static let captureLimit: TimeInterval = 15 * 60
    /// Less audio than this is discarded without a word (rule 4): it was a tap, not speech.
    public static let minimumAudio: TimeInterval = 0.15
    /// A recording at least this long that produced no text shows the "nothing heard" notice (rule 8).
    public static let nothingHeardAfter: TimeInterval = 1
    /// With prompt mode on, a hold released sooner than this after its press is a tap (rule 5).
    public static let tapHold: TimeInterval = 0.3
    /// How soon after a tap the next Hold to Talk press must come to start a prompt dictation (rule 5).
    public static let tapWindow: TimeInterval = 0.4
    /// How long an information notice stays (rule 12).
    public static let informationNotice: TimeInterval = 1.4
    /// How long an error notice stays (rule 12).
    public static let errorNotice: TimeInterval = 4
}

// MARK: - Identity

/// One Paste Again. Numbers only grow, so a report from an earlier replay never frees a later one.
public struct ReplayID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) { self.rawValue = rawValue }

    public static func < (lhs: ReplayID, rhs: ReplayID) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { "replay \(rawValue)" }
}

/// One notice. Each notice has its own id so that the timer of one it replaced cannot dismiss it.
public struct NoticeID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) { self.rawValue = rawValue }

    public static func < (lhs: NoticeID, rhs: NoticeID) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { "notice \(rawValue)" }
}

/// A timer the session arms. Each one names what it belongs to, and each is armed at most once, so a timer that
/// fires after its phase ended is recognised and dropped.
public enum TimerID: Hashable, Sendable {
    /// The capture of this dictation has this long to start (rule 1).
    case captureStart(DictationID)
    /// The stopped capture of this dictation has this long to deliver its last audio (rule 4).
    case captureDrain(DictationID)
    /// This dictation's recording reaches the 15 minute limit (rule 3).
    case captureLimit(DictationID)
    /// This notice expires (rule 12).
    case notice(NoticeID)
}

// MARK: - Settings

/// The user's settings that the session reads. The runtime takes a fresh copy for every event, so a change applies
/// from the next event on; what a dictation needs to keep (its style, its text rules) is fixed when it starts.
public struct SessionSettings: Sendable, Equatable {
    /// Prompt mode: a double tap of Hold to Talk starts a dictation in prompt style (rule 5). Off by default.
    public var promptMode: Bool
    /// Put the previous clipboard back after a paste.
    public var restoreClipboard: Bool
    /// The chosen microphone's unique identifier, or nil for the system default.
    public var microphoneID: String?
    /// Ask the engine to keep what a correction suggestion needs. The app sets this when suggestions are on, the
    /// dictionary is readable and Accessibility is trusted (docs/dictionary/DESIGN.md, section 3.4).
    public var retainForCorrection: Bool

    public init(promptMode: Bool = false, restoreClipboard: Bool = true, microphoneID: String? = nil,
                retainForCorrection: Bool = false) {
        self.promptMode = promptMode
        self.restoreClipboard = restoreClipboard
        self.microphoneID = microphoneID
        self.retainForCorrection = retainForCorrection
    }
}

// MARK: - Notices

/// One short message for the pill. It expires by its own timer (rule 12).
public struct Notice: Sendable, Equatable {
    public let id: NoticeID
    public let message: NoticeMessage

    public init(id: NoticeID, message: NoticeMessage) {
        self.id = id
        self.message = message
    }

    /// Whether the pill shows this as an error, which also decides how long it stays.
    public var kind: NoticeKind { message.kind }
}

/// Information is shown only when nothing else is going on; an error is shown over the wait for a transcript.
public enum NoticeKind: Sendable, Equatable {
    case information
    case error

    /// How long a notice of this kind stays on screen.
    public var lifetime: TimeInterval {
        switch self {
        case .information: SessionTiming.informationNotice
        case .error: SessionTiming.errorNotice
        }
    }
}

/// What a notice says. The session decides which message; `text` is what the user reads.
public enum NoticeMessage: Sendable, Equatable {
    /// Three dictations already exist, so a press started nothing (rule 1).
    case busy
    /// Sorello may not use the microphone (rules 1 and 2).
    case microphoneDenied
    /// The speech model could not be prepared, so a press started nothing (rule 1).
    case engineFailed(EngineFailure)
    /// The microphone did not start in time, or failed while starting (rule 10).
    case microphoneUnavailable
    /// A recording of a second or more produced no text (rule 8).
    case nothingHeard
    /// Transcription failed; the audio is in the Run Log for a retry (rule 10).
    case transcriptionFailed
    /// The text could not be pasted for the user, so it is on the clipboard for them to paste (rule 9).
    case leftOnClipboard(ClipboardReason)
    /// The insertion failed (rule 9). A Return that could not be posted says so.
    case insertionFailed(InsertionFailure)

    /// Errors outrank the wait for a transcript in the pill. Every message but "nothing heard" needs the user to
    /// notice it even while another dictation is still being transcribed, so only that one is information.
    public var kind: NoticeKind {
        switch self {
        case .nothingHeard: .information
        default: .error
        }
    }

    /// The line the pill shows.
    public var text: String {
        switch self {
        case .busy:
            String(localized: "Still working on earlier dictations",
                   comment: "Notice: a dictation could not start because three are already in progress")
        case .microphoneDenied:
            String(localized: "Microphone access is off in System Settings",
                   comment: "Notice: the user has not allowed the microphone")
        case .engineFailed(.modelMissing):
            String(localized: "This build has no speech model",
                   comment: "Notice: the app was built without the speech model")
        case .engineFailed(.modelCorrupt):
            String(localized: "The speech model is damaged. Reinstall the app.",
                   comment: "Notice: a model file does not match its manifest")
        case .engineFailed(.loadFailed):
            String(localized: "The speech model couldn't load",
                   comment: "Notice: the speech model failed to load")
        case .microphoneUnavailable:
            String(localized: "The microphone didn't start",
                   comment: "Notice: the microphone failed or timed out while starting")
        case .nothingHeard:
            String(localized: "Nothing heard", comment: "Notice: a recording produced no text")
        case .transcriptionFailed:
            String(localized: "Transcription failed. Retry it from the Run Log.",
                   comment: "Notice: transcription failed; the audio is kept in the Run Log")
        case .leftOnClipboard(.accessibilityMissing):
            String(localized: "Copied. Allow Accessibility to paste automatically.",
                   comment: "Notice: the text is on the clipboard because Accessibility is not allowed")
        case .leftOnClipboard(.targetChanged):
            String(localized: "The window changed. Press ⌘V to paste.",
                   comment: "Notice: the text is on the clipboard because the focused field changed")
        case .leftOnClipboard:
            String(localized: "Copied. Press ⌘V to paste.",
                   comment: "Notice: the text is on the clipboard for the user to paste")
        case .insertionFailed(.commandNotPosted):
            String(localized: "Return couldn't be pressed", comment: "Notice: a spoken \"press enter\" failed")
        case .insertionFailed:
            String(localized: "Couldn't paste. The text is in the Run Log.",
                   comment: "Notice: the paste failed; the text is kept in the Run Log")
        }
    }
}

// MARK: - The microphone slot

/// A press that is waiting for the answer to the microphone permission prompt (rule 2). A hold intent exists only
/// while its key is down: releasing the key clears it.
public struct PermissionIntent: Sendable, Equatable {
    public let mode: TriggerMode
    /// When the press arrived, on `SessionClock`'s timeline.
    public let pressTime: TimeInterval

    public init(mode: TriggerMode, pressTime: TimeInterval) {
        self.mode = mode
        self.pressTime = pressTime
    }
}

/// The dictation that holds the microphone, while it starts or records.
public struct LiveDictation: Sendable, Equatable {
    public let id: DictationID
    public let mode: TriggerMode
    public let style: DictationStyle
    /// When the press that started it arrived, on `SessionClock`'s timeline. The pill counts elapsed time from
    /// here, and the double tap measures the hold from here.
    public let pressTime: TimeInterval
    /// Whether this hold takes part in the double tap at all: prompt mode was on when it was pressed and has not
    /// been seen off since. Only such a hold is discarded when released quickly (rule 5).
    var tapEnrolled: Bool
    /// Whether a quick release of this hold arms the double tap: it is enrolled, nothing at all was in progress at
    /// the press, it is not itself a prompt dictation, and no other trigger has arrived since (rule 5).
    var mayArmTap: Bool
}

/// The microphone slot. One case, so two captures, or a capture without a dictation, cannot be written down.
public enum CaptureState: Sendable, Equatable {
    case idle
    /// The permission prompt is up. The intent is the press to honour when access is granted, if it still stands.
    case awaitingPermission(PermissionIntent?)
    /// `startCapture` has been asked for. `stopRequested` remembers a stop that arrived before the capture did
    /// (rule 3).
    case starting(LiveDictation, stopRequested: Bool)
    case recording(LiveDictation)

    /// The dictation that holds the microphone, if any.
    public var live: LiveDictation? {
        switch self {
        case .starting(let live, _), .recording(let live): live
        case .idle, .awaitingPermission: nil
        }
    }
}

// MARK: - The pipeline and the output slot

/// A dictation whose audio has stopped, waiting for its last audio, its transcript, or its turn to be inserted.
public struct PipelineItem: Sendable, Equatable {
    public let id: DictationID
    public let style: DictationStyle
    public internal(set) var phase: Phase

    /// Where a stopped dictation is on its way to the cursor. The item being inserted is not here: it is held by
    /// `OutputState.inserting`, so an insertion without the output slot cannot be written down.
    public enum Phase: Sendable, Equatable {
        /// `stopCapture` was asked for; waiting for `capture.ended`. `drainTimerArmed` is false once the drain
        /// timer has fired and the capture was aborted.
        case draining(drainTimerArmed: Bool)
        /// The stream is finishing. `audio` is how long the recording was, in seconds.
        case transcribing(audio: TimeInterval)
        /// The transcript is in; waiting for every older dictation to be inserted first.
        case ready(SpeechResult)
    }
}

/// The dictation that owns the output slot while it is inserted.
public struct InsertingDictation: Sendable, Equatable {
    public let id: DictationID
    public let style: DictationStyle
    public let speech: SpeechResult
}

/// The output slot: one insertion or one replay at a time.
public enum OutputState: Sendable, Equatable {
    case free
    case inserting(InsertingDictation)
    case replaying(ReplayID)
}

/// The double tap's arm: a qualifying tap was released at this time (rule 5).
public struct TapArm: Sendable, Equatable {
    public let releaseTime: TimeInterval

    /// Whether a Hold to Talk press at `time` is the second tap. The window is inclusive at both ends and measured
    /// from an absolute deadline, so the boundary holds at any point on the timeline.
    func admits(_ time: TimeInterval) -> Bool {
        time >= releaseTime && time <= releaseTime + SessionTiming.tapWindow
    }
}

// MARK: - The state

/// Everything the session knows about dictation, in one value. `Session.reduce` is the only thing that changes it.
public struct SessionState: Sendable, Equatable {
    /// The microphone slot.
    public internal(set) var capture: CaptureState = .idle
    /// Dictations whose audio has stopped and that are not being inserted, oldest first.
    public internal(set) var pipeline: [PipelineItem] = []
    /// The insertion or replay under way.
    public internal(set) var output: OutputState = .free
    public internal(set) var microphone: MicrophoneAccess = .unknown
    public internal(set) var engine: EngineReadiness = .preparing
    /// The message on the pill, if any.
    public internal(set) var notice: Notice?
    /// The last text inserted or left on the clipboard, for Paste Again. Never empty.
    public internal(set) var lastText: String?
    /// The double tap's arm, if a tap is waiting for its second press.
    public internal(set) var tap: TapArm?

    var nextDictation: UInt64 = 1
    var nextNotice: UInt64 = 1
    var nextReplay: UInt64 = 1

    public init() {}

    /// How many dictations exist: the one holding the microphone, the pipeline and the one being inserted.
    public var dictationCount: Int {
        (capture.live == nil ? 0 : 1) + pipeline.count + (insertingID == nil ? 0 : 1)
    }

    /// Every dictation the session holds, oldest first: the one being inserted, the pipeline, then the live one.
    public var dictationIDs: [DictationID] {
        var ids: [DictationID] = []
        if let insertingID { ids.append(insertingID) }
        ids += pipeline.map(\.id)
        if let live = capture.live { ids.append(live.id) }
        return ids
    }

    /// Whether the session holds this dictation. An event naming one it does not hold is stale.
    public func holds(_ id: DictationID) -> Bool {
        capture.live?.id == id || insertingID == id || pipeline.contains { $0.id == id }
    }

    /// Whether this timer is armed and not yet fired or cancelled. A timer event is acted on only then.
    public func isArmed(_ timer: TimerID) -> Bool {
        switch timer {
        case .captureStart(let id):
            if case .starting(let live, _) = capture { return live.id == id }
            return false
        case .captureLimit(let id):
            if case .recording(let live) = capture { return live.id == id }
            return false
        case .captureDrain(let id):
            return pipeline.contains { $0.id == id && $0.phase == .draining(drainTimerArmed: true) }
        case .notice(let id):
            return notice?.id == id
        }
    }

    var insertingID: DictationID? {
        if case .inserting(let item) = output { return item.id }
        return nil
    }
}
