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
}

/// Receives triggers on the main actor, in the order they happened.
@MainActor
public protocol TriggerHandling: AnyObject {
    /// `time` is monotonic seconds on `SessionClock`'s timeline, taken when the event arrived. Returns whether the
    /// trigger did something; the shortcut adapter consumes Escape only when this is true.
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
    case interrupted(CaptureInterruption)
}

public protocol AudioCapturing: Sendable {
    /// Starts the microphone and returns once it is running. Throws `CaptureFailure`; gives up after 2 s.
    func start(_ request: CaptureRequest) async throws -> any AudioCapture
}

/// One running capture. The microphone is in use from `start` until `stop` or `abort` returns.
public protocol AudioCapture: Sendable {
    /// Events in recording order. Finishes after `stop()` has delivered the last samples, or at once after `abort()`.
    var events: AsyncStream<CaptureEvent> { get }
    /// Stops the microphone, delivers what remains, then finishes `events`. Safe to call more than once.
    func stop() async
    /// Stops the microphone and discards what was not yet delivered. Safe to call more than once.
    func abort()
}

/// Hears every chunk as it is captured, to show the voice. Called off the main actor, often; must not block.
public protocol LevelSink: Sendable {
    func heard(_ samples: [Float], at time: TimeInterval)
    /// The capture ended or was discarded: the level falls to rest.
    func captureEnded()
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
    func prepare() async
    /// The current readiness, then every change.
    func readiness() -> AsyncStream<EngineReadiness>
    /// Opens a stream for one dictation. Cheap, and never waits for the model.
    func openStream(_ options: SpeechStreamOptions) -> any SpeechStreaming
}

/// One dictation's audio on its way to text. Chunks are transcribed as they fill, while recording continues.
public protocol SpeechStreaming: Sendable {
    /// Adds samples in recording order. Never waits for model work.
    func append(_ samples: [Float])
    /// Ends the audio and returns the transcript, waiting for preparation if the engine is not ready yet.
    /// Throws `SpeechFailure`.
    func finish() async throws -> SpeechResult
    /// Drops the audio and any partial result, and keeps nothing. Safe to call more than once.
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

public protocol InsertionContextReading: Sendable {
    /// Up to 16 characters each side of the cursor in the focused field. Nil when unknown, for a secure field, or
    /// when the app in front has not answered within 0.3 s.
    func read() async -> InsertionContext?
}

/// A transcript after the text rules.
public struct ProcessedDictation: Sendable, Equatable {
    /// What was heard, for the Run Log.
    public var raw: String
    /// What to insert. Empty when nothing was said.
    public var text: String
    public var pressEnter: Bool
    public var usedMacro: Bool
    public var addedPromptTag: Bool

    public init(raw: String, text: String, pressEnter: Bool = false, usedMacro: Bool = false,
                addedPromptTag: Bool = false) {
        self.raw = raw
        self.text = text
        self.pressEnter = pressEnter
        self.usedMacro = usedMacro
        self.addedPromptTag = addedPromptTag
    }
}

public protocol TranscriptProcessing: Sendable {
    /// Applies the user's text rules. Pure: the same input gives the same output until the settings change.
    func process(_ transcript: String, style: DictationStyle, context: InsertionContext?) -> ProcessedDictation
}

public struct InsertionPlan: Sendable, Equatable {
    public var text: String
    /// Press Return after the text.
    public var pressEnter: Bool
    /// Put the previous clipboard back afterwards.
    public var restoreClipboard: Bool

    public init(text: String, pressEnter: Bool = false, restoreClipboard: Bool = true) {
        self.text = text
        self.pressEnter = pressEnter
        self.restoreClipboard = restoreClipboard
    }
}

public enum InsertionOutcome: Sendable, Equatable {
    case inserted
    /// The text could not be pasted for the user, so it was left on the clipboard for them to paste.
    case leftOnClipboard(ClipboardReason)
    case failed(InsertionFailure)
}

public enum ClipboardReason: Sendable, Equatable {
    /// Without Accessibility no key can be posted.
    case accessibilityMissing
}

public enum InsertionFailure: Sendable, Equatable {
    case pasteboardUnavailable
    case eventPostFailed
}

public protocol TextInserting: Sendable {
    func insert(_ plan: InsertionPlan) async -> InsertionOutcome
}

// MARK: - Reading the focused text field

/// The process in front and its focused text element. Opaque outside the adapter that made it.
public struct TextFieldTarget: @unchecked Sendable {
    // Safe: `element` is an immutable Accessibility reference (an AXUIElement on macOS), which may be used from any
    // thread; this value never mutates it.
    public let pid: Int32
    public let element: AnyObject

    public init(pid: Int32, element: AnyObject) {
        self.pid = pid
        self.element = element
    }
}

/// UTF-16 offsets, as Accessibility reports them.
public struct TextFieldRange: Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public enum TextFieldCheck: Equatable, Sendable {
    case ok, focusChanged, secure, failed
}

/// Bounded reads of one text field in another app. Implementations never read a whole value, and never a secure
/// field (ARCHITECTURE.md, section 9).
public protocol TextFieldReading: AnyObject, Sendable {
    func isTrusted() -> Bool
    /// The focused element of the app in front, if it is another app's editable text area, text field or combo box
    /// and not a secure field.
    func captureFocusedTextField() -> TextFieldTarget?
    /// Whether `target` is still the same process's focused element, and still not secure.
    func check(_ target: TextFieldTarget) -> TextFieldCheck
    func characterCount(_ target: TextFieldTarget) -> Int?
    func selectedRange(_ target: TextFieldTarget) -> TextFieldRange?
    /// The text in `range`, or nil when unsupported or on any error.
    func string(_ target: TextFieldTarget, range: TextFieldRange) -> String?
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
    /// What was heard; empty when transcription failed.
    public var raw: String
    /// What was inserted; empty when transcription failed.
    public var text: String
    public var outcome: DictationOutcome
    /// The recording, 16 kHz mono.
    public var samples: [Float]

    public init(date: Date, raw: String, text: String, outcome: DictationOutcome, samples: [Float]) {
        self.date = date
        self.raw = raw
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
