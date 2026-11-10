import Foundation

// The ports of the dictation session (ARCHITECTURE.md, section 4): the values that cross a module boundary and the
// protocols each adapter implements. The session depends on these and on nothing else, so every one of them can be
// faked in a test. Changing a declaration here changes the contract for several modules at once: do it in its own
// commit, with the reason.

// MARK: - Identity

/// One recording and what becomes of it. Numbers only grow, so an older dictation always compares lower.
public struct DictationID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) { self.rawValue = rawValue }

    public static func < (lhs: DictationID, rhs: DictationID) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { "#\(rawValue)" }
}

/// How a dictation was started, which decides how it stops.
public enum TriggerMode: Sendable, Equatable {
    /// Records while the shortcut is down.
    case hold
    /// Starts on one press and stops on the next.
    case toggle
}

/// What kind of text a dictation produces.
public enum DictationStyle: Sendable, Equatable {
    case plain
    /// Prefixed with the prompt tag, so an AI agent reading it knows it was dictated.
    case prompt
}

/// An application, as the dictionary's per-app limits name it. Nothing else about an app is ever kept.
public struct AppIdentity: Sendable, Equatable, Hashable, Codable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

// MARK: - Shortcuts and triggers

/// Modifier state without sides, for a shortcut that is a key with modifiers ("⌥Space").
public struct ModifierFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = ModifierFlags(rawValue: 1 << 0)
    public static let option = ModifierFlags(rawValue: 1 << 1)
    public static let control = ModifierFlags(rawValue: 1 << 2)
    public static let shift = ModifierFlags(rawValue: 1 << 3)
    public static let function = ModifierFlags(rawValue: 1 << 4)
}

/// One physical modifier key, for a shortcut that is modifier keys alone ("Right ⌥", "Fn").
public enum ModifierKey: String, Codable, CaseIterable, Hashable, Sendable {
    case leftCommand, rightCommand, leftOption, rightOption, leftControl, rightControl, leftShift, rightShift, function
}

/// What the user presses for an action (ARCHITECTURE.md, section 6, "Shortcuts").
public enum ShortcutBinding: Codable, Hashable, Sendable {
    /// A key, by its virtual key code, with any modifiers. The binding consumes that key's events.
    case key(code: UInt16, modifiers: ModifierFlags)
    /// Exactly these modifier keys and no others. The binding consumes nothing.
    case modifiers(Set<ModifierKey>)

    /// The default Hold to Talk shortcut.
    public static let function = ShortcutBinding.modifiers([.function])
}

public enum ShortcutAction: String, Codable, CaseIterable, Hashable, Sendable {
    case holdToTalk, tapToToggle, pasteAgain
}

/// How a hold ended.
public enum ReleaseOrigin: Sendable, Equatable {
    /// The shortcut's own key came up.
    case keyUp
    /// The shortcut ended some other way: the event tap was disabled, or the system took the keyboard.
    case interrupted
}

/// What the user asked for, as the shortcut adapter or the pill reports it.
public enum TriggerEvent: Sendable, Equatable {
    case holdPressed
    case holdReleased(ReleaseOrigin)
    /// The hold turned out to be the start of a chord (another key within 0.3 s): discard it silently.
    case holdAbandoned
    case togglePressed
    /// Escape.
    case cancelPressed
    case pasteAgainPressed
    case pillStopClicked
    case pillCancelClicked
    /// The session was locked or switched to another user, or the Mac is about to sleep. Whatever the shortcut
    /// mode, a recording stops here and nothing resumes by itself afterwards.
    case systemInterrupted
}

/// Receives triggers on the main actor, in the order they happened.
@MainActor
public protocol TriggerHandling: AnyObject {
    /// `time` is monotonic seconds on `SessionClock`'s timeline, taken when the event arrived. Returns whether the
    /// trigger did something; the shortcut adapter consumes Escape only when this is true.
    ///
    /// This is called from inside the keyboard event tap, so it decides and returns: it never waits for
    /// Accessibility, capture, speech or the disk. Whatever the trigger sets in motion happens after it returns.
    @discardableResult
    func handle(_ trigger: TriggerEvent, at time: TimeInterval) -> Bool
}

// MARK: - Audio

public enum AudioFormat {
    /// Every sample that crosses a port is 16 kHz mono `Float` in -1...1.
    public static let sampleRate = 16_000.0
}

public struct AudioChunk: Sendable, Equatable {
    public var samples: [Float]
    /// Monotonic seconds, on `SessionClock`'s timeline, at which the chunk's last sample was heard.
    public var time: TimeInterval

    public init(samples: [Float], time: TimeInterval) {
        self.samples = samples
        self.time = time
    }
}

public struct CaptureRequest: Sendable, Equatable {
    /// The chosen microphone's unique identifier, or nil for the system default.
    public var deviceID: String?

    public init(deviceID: String? = nil) { self.deviceID = deviceID }
}

public enum CaptureFailure: Error, Sendable, Equatable {
    case permissionDenied
    case noInputDevice
    case deviceUnavailable
    case startTimedOut
    case failed
}

public enum CaptureInterruption: Sendable, Equatable {
    case deviceRemoved
    case systemSleep
    case sessionInterrupted
}

public enum CaptureEvent: Sendable, Equatable {
    case chunk(AudioChunk)
    /// No audio arrived for 2 s. Sent once; the capture keeps running until stopped.
    case stalled
    /// The device went away or the system took the audio session. The capture keeps what it has until stopped.
    case interrupted(CaptureInterruption)
    /// The capture broke for another reason. It keeps what it has until stopped.
    case failed(CaptureFailure)
}

public protocol AudioCapturing: Sendable {
    /// Starts the microphone and returns once it is running. Throws `CaptureFailure`; gives up after 3 s.
    ///
    /// Honours task cancellation: it either throws after releasing the microphone or returns one live capture,
    /// never both and never neither. Starts and teardowns run one at a time in the order asked, so `start` may be
    /// called while an earlier capture is still being torn down.
    func start(_ request: CaptureRequest) async throws -> any AudioCapture
}

/// One running capture. The microphone is held from `start` until `stop` or `abort` has torn it down.
public protocol AudioCapture: Sendable {
    /// Events in recording order, for exactly one consumer. Nothing is dropped: the stream buffers without limit.
    /// It finishes after `stop()` has delivered the last samples, or at once after `abort()`.
    var events: AsyncStream<CaptureEvent> { get }
    /// Stops the microphone, delivers what remains (including the converter's tail), then finishes `events`.
    /// Safe to call more than once. After `abort()` it does nothing.
    func stop() async
    /// Finishes `events` at once and stops the microphone. Chunks already yielded into `events` stay there for
    /// the consumer to read; samples not yet yielded are discarded. Wins over a `stop()` in progress. Safe to
    /// call more than once, from any thread; it returns immediately and the teardown completes on the adapter's
    /// own queue, before any later capture gets the microphone.
    func abort()
}

/// Hears every chunk as it is captured, to show the voice. Called off the main actor, often; must not block.
///
/// The picture follows the newest dictation only. Once a chunk from a dictation has been accepted, `heard` and
/// `captureEnded` for any older dictation are ignored, and a dictation that has ended cannot be revived by a
/// late chunk. This is a filter for the display: the audio itself still goes to speech and the Run Log.
public protocol LevelSink: Sendable {
    func heard(_ samples: [Float], at time: TimeInterval, dictation: DictationID)
    /// That dictation's capture ended or was discarded: the level falls to rest.
    func captureEnded(dictation: DictationID)
}

// MARK: - Speech

public enum EngineFailure: Error, Sendable, Equatable {
    /// The app was built without the model.
    case modelMissing
    /// A model file does not match its manifest.
    case modelCorrupt
    case loadFailed
}

public enum EngineReadiness: Sendable, Equatable {
    case preparing
    case ready
    case failed(EngineFailure)
}

public struct SpeechStreamOptions: Sendable, Equatable {
    /// The app in front when the dictation started, for the dictionary's per-app words.
    public var appBundleID: String?
    /// Keep what a correction suggestion needs to decode this audio again. Held in memory only.
    public var retainForCorrection: Bool

    public init(appBundleID: String? = nil, retainForCorrection: Bool = false) {
        self.appBundleID = appBundleID
        self.retainForCorrection = retainForCorrection
    }
}

public struct SpeechResult: Sendable, Equatable {
    /// The transcript with the dictionary's casing applied, before any text rule. Empty when nothing was said.
    public var text: String
    /// Names the retained audio, when `retainForCorrection` was set and something was kept.
    public var correctionID: UInt64?

    public init(text: String, correctionID: UInt64? = nil) {
        self.text = text
        self.correctionID = correctionID
    }
}

public enum SpeechFailure: Error, Sendable, Equatable {
    case engineUnavailable(EngineFailure)
    case cancelled
    case failed
}

public protocol SpeechTranscribing: Sendable {
    /// Loads and warms the model, or tries again after a failure. Returns when the engine is ready or has failed.
    /// Concurrent calls share one attempt.
    func prepare() async
    /// The current readiness, then every change. Each call is an independent subscription. It ends when the
    /// consuming task is cancelled or the stream is released, so a consumer that stops reading early must let go
    /// of the stream; merely leaving the loop does not end it.
    func readiness() -> AsyncStream<EngineReadiness>
    /// Opens a stream for one dictation. Cheap, synchronous, and never waits for the model.
    func openStream(_ options: SpeechStreamOptions) -> any SpeechStreaming
}

/// One dictation's audio on its way to text. Chunks are transcribed as they fill, while recording continues.
///
/// A stream is an object of its own with a synchronized ingress in front of the engine's single model queue, which
/// is why these are plain synchronous calls from any thread.
public protocol SpeechStreaming: Sendable {
    /// Adds samples; they are transcribed in the order `append` was called. Never waits for model work. Ignored
    /// after `finish` or `cancel`.
    func append(_ samples: [Float])
    /// Ends the audio and returns the transcript, waiting for preparation if the engine is not ready yet. Call
    /// once. Throws `SpeechFailure`: `engineUnavailable` as soon as preparation has failed, `cancelled` promptly
    /// if `cancel` is called or the calling task is cancelled.
    func finish() async throws -> SpeechResult
    /// Drops the audio and any partial result, and keeps nothing. Wins over `finish`. Safe to call more than once.
    func cancel()
}

// MARK: - Text

/// The text just before and after the insertion point; either side is nil when it could not be read.
public struct InsertionContext: Sendable, Equatable {
    public var before: String?
    public var after: String?

    public init(before: String?, after: String?) {
        self.before = before
        self.after = after
    }
}

/// A transcript after the text rules.
public struct ProcessedDictation: Sendable, Equatable {
    /// The recognizer's transcript, unchanged: what the Run Log shows as heard.
    public var heard: String
    /// What to insert. Empty when the dictation was only a command ("press enter") or a macro with no text.
    public var text: String
    /// Press Return after the text. May be true with empty `text`.
    public var pressEnter: Bool
    public var usedMacro: Bool
    public var addedPromptTag: Bool

    public init(heard: String, text: String, pressEnter: Bool = false, usedMacro: Bool = false,
                addedPromptTag: Bool = false) {
        self.heard = heard
        self.text = text
        self.pressEnter = pressEnter
        self.usedMacro = usedMacro
        self.addedPromptTag = addedPromptTag
    }
}

/// The user's text rules as they were when a dictation started. A value of this type never changes, so editing a
/// macro while a dictation waits does not change that dictation.
public protocol TranscriptProcessing: Sendable {
    func process(_ transcript: String, style: DictationStyle, context: InsertionContext?) -> ProcessedDictation
}

/// The field and selection the inserter read its context from, for the app's correction watch. Only the adapter
/// that made it, and the app code that wires that adapter up, look inside; the session passes it along unopened.
public struct DestinationField: Sendable {
    public let value: any Sendable

    public init(_ value: any Sendable) { self.value = value }
}

/// Where an insertion's text is going, as `compose` is told.
public enum InsertionDestination: Sendable {
    /// To the cursor in the app in front. `context` is nil when the field could not be read; the paste still
    /// goes ahead. `field` is present only when the field and its selection were read.
    case cursor(context: InsertionContext?, field: DestinationField?)
    /// Only to the clipboard. Nothing will be posted and no field was read.
    case clipboard(ClipboardReason)
}

/// What `compose` hands back to the inserter once the destination is known.
public struct ComposedInsertion: Sendable, Equatable {
    public var text: String
    /// Press Return after the text. With empty `text`, Return is posted alone and the clipboard is not touched.
    public var pressEnter: Bool

    public init(text: String, pressEnter: Bool = false) {
        self.text = text
        self.pressEnter = pressEnter
    }
}

public enum InsertionOutcome: Sendable, Equatable {
    /// The paste (or the lone Return) was posted. The system does not say whether the app accepted it. A Return
    /// that was skipped after a posted paste is still `inserted`.
    case inserted
    /// `compose` returned no text and no Return.
    case nothingToInsert
    /// The text could not be pasted for the user, so it was left on the clipboard for them to paste.
    case leftOnClipboard(ClipboardReason)
    case failed(InsertionFailure)
}

public enum ClipboardReason: Sendable, Equatable {
    /// Without Accessibility no key can be posted.
    case accessibilityMissing
    /// A modifier key was still held after the wait: a paste posted then would be a different shortcut.
    case modifiersStillDown
    case screenLocked
    /// The app in front, its focused field or its selection changed while the text was being composed.
    case targetChanged
}

public enum InsertionFailure: Sendable, Equatable {
    case pasteboardUnavailable
    case eventPostFailed
    /// The dictation was only a command (Return) and it could not be posted. Nothing went to the clipboard.
    case commandNotPosted
    /// The caller was cancelled before any key was posted. Anything written to the clipboard was put back.
    case cancelled
}

public protocol TextInserting: Sendable {
    /// Runs one insertion transaction (ARCHITECTURE.md, section 6, "Text insertion"). Transactions run one at a
    /// time in the order asked.
    ///
    /// `compose` is called exactly once per transaction that gets as far as needing the text, and before
    /// anything is pasted or written. It is told where the text is going and returns what to insert. After it
    /// returns, the adapter checks the destination again before posting.
    ///
    /// The call returns when the outcome of posting is known. Return and restoring the clipboard finish
    /// afterwards on the adapter's own account, whatever happens to the caller, and before the next transaction
    /// begins. If the caller's task is cancelled before any key is posted the outcome is `failed(.cancelled)`;
    /// after a key is posted, cancellation changes nothing and nothing is ever posted twice.
    func insert(restoreClipboard: Bool,
                compose: @escaping @Sendable (InsertionDestination) async -> ComposedInsertion) async -> InsertionOutcome
}

// MARK: - Permissions and the app in front

public enum MicrophoneAccess: Sendable, Equatable {
    case unknown, granted, denied
}

public protocol MicrophoneAuthorizing: Sendable {
    func current() -> MicrophoneAccess
    /// Asks the user if access is `unknown`; otherwise returns the current access.
    func request() async -> MicrophoneAccess
}

public protocol FrontmostAppReading: Sendable {
    /// The app in front, or nil when it is Sorello itself or cannot be named.
    @MainActor func frontmostApp() -> AppIdentity?
}

// MARK: - Run Log

/// How a dictation that produced text ended. Dictations in which nothing was heard are not recorded.
public enum DictationOutcome: String, Codable, Sendable, Equatable {
    case inserted
    case leftOnClipboard
    case insertionFailed
    case transcriptionFailed
}

public struct HistoryDraft: Sendable, Equatable {
    public var date: Date
    /// The recognizer's transcript; empty when transcription failed.
    public var heard: String
    /// What was inserted; empty when transcription failed.
    public var text: String
    public var outcome: DictationOutcome
    /// The recording, 16 kHz mono.
    public var samples: [Float]

    public init(date: Date, heard: String, text: String, outcome: DictationOutcome, samples: [Float]) {
        self.date = date
        self.heard = heard
        self.text = text
        self.outcome = outcome
        self.samples = samples
    }
}

public protocol HistoryRecording: Sendable {
    /// Saves the entry and its audio. Failures are swallowed: the Run Log never interrupts dictation.
    func record(_ draft: HistoryDraft) async
}

// MARK: - Time

/// Monotonic time for the session. Tests drive a manual clock.
public protocol SessionClock: Sendable {
    /// Seconds since an arbitrary fixed point; never goes backwards.
    var now: TimeInterval { get }
    /// Suspends for `seconds`, or throws `CancellationError`.
    func sleep(for seconds: TimeInterval) async throws
}

/// The system's uptime, which is also the timeline of keyboard events.
public struct SystemSessionClock: SessionClock {
    public init() {}

    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(seconds, 0)))
    }
}
