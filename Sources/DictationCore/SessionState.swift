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
    /// Unless the double tap is set to nothing, a hold released sooner than this after its press is a tap (rule 5).
    public static let tapHold: TimeInterval = 0.3
    /// How soon after a tap the next Hold to Talk press must come to be the double tap's second press (rule 5).
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

/// What a double tap of Hold to Talk starts (rule 5). The user chooses it; a hands-free dictation is the default.
public enum DoubleTapAction: Sendable, Equatable, CaseIterable {
    /// A toggle recording in plain style: it goes on with no key held until Hold to Talk is tapped once more, or
    /// anything else that stops a toggle recording stops it.
    case handsFree
    /// A hold in prompt style: the second press is held, and the text starts with the prompt tag.
    case prompt
    /// Nothing: a quick hold is an ordinary hold, and two taps start nothing special.
    case off
}

/// The user's settings that the session reads. The runtime takes a fresh copy for every event, so a change applies
/// from the next event on; what a dictation needs to keep (its style, its text rules) is fixed when it starts.
public struct SessionSettings: Sendable, Equatable {
    /// What a double tap of Hold to Talk starts (rule 5). A hands-free dictation by default.
    public var doubleTap: DoubleTapAction
    /// Put the previous clipboard back after a paste.
    public var restoreClipboard: Bool
    /// The chosen microphone's unique identifier, or nil for the system default.
    public var microphoneID: String?
    /// Record from another microphone when the system default is a Bluetooth one (`CaptureRequest.avoidBluetooth`).
    /// On by default.
    public var avoidBluetoothMicrophone: Bool
    /// Ask the engine to keep what a correction suggestion needs. The app sets this when suggestions are on, the
    /// dictionary is readable and Accessibility is trusted (docs/dictionary/DESIGN.md, section 3.4).
    public var retainForCorrection: Bool

    public init(doubleTap: DoubleTapAction = .handsFree, restoreClipboard: Bool = true, microphoneID: String? = nil,
                avoidBluetoothMicrophone: Bool = true, retainForCorrection: Bool = false) {
        self.doubleTap = doubleTap
        self.restoreClipboard = restoreClipboard
        self.microphoneID = microphoneID
        self.avoidBluetoothMicrophone = avoidBluetoothMicrophone
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
            String(localized: "The speech model isn’t downloaded yet",
                   comment: "Notice: a dictation could not start because the speech model is not on this Mac")
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
    /// Whether the hold takes part in the double tap once it starts: the double tap was not set to nothing at the
    /// press and has not been seen set to nothing since (rule 5).
    var tapEnrolled: Bool

    public init(mode: TriggerMode, pressTime: TimeInterval) {
        self.init(mode: mode, pressTime: pressTime, tapEnrolled: false)
    }

    init(mode: TriggerMode, pressTime: TimeInterval, tapEnrolled: Bool) {
        self.mode = mode
        self.pressTime = pressTime
        self.tapEnrolled = tapEnrolled
    }
}

/// The dictation that holds the microphone, while it starts or records.
public struct LiveDictation: Sendable, Equatable {
    public let id: DictationID
    public let style: DictationStyle
    /// When the press that started it arrived, on `SessionClock`'s timeline. The pill counts elapsed time from
    /// here, and the double tap measures the hold from here.
    public let pressTime: TimeInterval
    /// How it records, and what the session remembers about the keys for it (rule 5).
    var keys: LiveKeys

    /// Hold to Talk records while its key is down; a toggle recording, hands-free ones included, until it is stopped.
    public var mode: TriggerMode {
        switch keys {
        case .hold: .hold
        case .toggle: .toggle
        }
    }
}

/// How the live dictation records, and what the session remembers about the keys for it. A hold carries its part in
/// the double tap; a toggle recording carries what Hold to Talk's key is doing during it. Neither can carry the
/// other's, so a hold that stops itself at a tap, or a toggle recording discarded as a quick release, cannot be
/// written down.
enum LiveKeys: Sendable, Equatable {
    /// Hold to Talk: it records while the key is down and stops when the key comes up.
    case hold(TapRole)
    /// A toggle recording, started by Tap to Toggle or by a hands-free double tap. `holdKey` is nil while Hold to
    /// Talk's key is up, as far as this recording is concerned.
    case toggle(holdKey: HoldKey?)
}

/// How a hold takes part in the double tap (rule 5).
enum TapRole: Sendable, Equatable {
    /// Not at all: the double tap was set to nothing when it was pressed, or has been seen set to nothing since.
    /// A quick release stops it like any hold.
    case outside
    /// A quick release discards it as a tap but arms nothing: something was in progress at the press, it is the
    /// held second press of a prompt double tap, it waited for permission, or another trigger has arrived since.
    case enrolled
    /// A quick release discards it and arms the double tap.
    case arming
}

/// Hold to Talk's key while it is down during a toggle recording (rule 5).
enum HoldKey: Sendable, Equatable {
    /// The second press of the double tap that started this hands-free recording. Its release does nothing; if it
    /// turns out to be the start of a chord, the recording is discarded like any abandoned hold.
    case starting
    /// A press that arrived during the recording. Released with a genuine key-up, it stops the recording; abandoned
    /// as a chord or ended without a key-up, it does nothing.
    case stopping
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
