import DictationCore
import Foundation
import Observation

/// Every user setting, typed, over a `UserDefaults` the caller supplies (ARCHITECTURE.md, section 7). The app passes
/// its own defaults; tests pass a suite of their own, so they never touch real settings.
///
/// Values are read once at creation and written through on every change. A stored value that no longer decodes
/// (an older format, or something written by hand) reads as that setting's default; the other settings are
/// unaffected. Observable, so a screen or the session's settings follow a change at once.
@MainActor
@Observable
public final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    /// Records while held. Defaults to Fn. Nil means the user removed it.
    public var holdToTalkShortcut: ShortcutBinding? {
        didSet { Keys.holdToTalkShortcut.write(holdToTalkShortcut, to: defaults) }
    }

    /// Starts on one press and stops on the next. Unset by default.
    public var tapToToggleShortcut: ShortcutBinding? {
        didSet { Keys.tapToToggleShortcut.write(tapToToggleShortcut, to: defaults) }
    }

    /// Inserts the last dictation again. Unset by default.
    public var pasteAgainShortcut: ShortcutBinding? {
        didSet { Keys.pasteAgainShortcut.write(pasteAgainShortcut, to: defaults) }
    }

    /// Put the user's clipboard back after pasting. On by default.
    public var restoreClipboard: Bool {
        didSet { Keys.restoreClipboard.write(restoreClipboard, to: defaults) }
    }

    /// Write spoken numbers as digits. On by default.
    public var spokenNumbers: Bool {
        didSet { Keys.spokenNumbers.write(spokenNumbers, to: defaults) }
    }

    /// Turn spoken pairs such as "quote … end quote" into punctuation. Off by default.
    public var spokenDelimiters: Bool {
        didSet { Keys.spokenDelimiters.write(spokenDelimiters, to: defaults) }
    }

    /// A trailing "press enter" presses Return after the paste. Off by default.
    public var pressEnterCommand: Bool {
        didSet { Keys.pressEnterCommand.write(pressEnterCommand, to: defaults) }
    }

    /// What a double tap of Hold to Talk starts. A hands-free dictation by default.
    public var doubleTap: DoubleTapAction {
        didSet { Keys.doubleTap.write(doubleTap, to: defaults) }
    }

    /// Put before a prompt-style dictation. `[dictated]` by default.
    public var promptTag: String {
        didSet { Keys.promptTag.write(promptTag, to: defaults) }
    }

    /// Offer to add a word the user corrects right after a dictation. On by default.
    public var correctionSuggestions: Bool {
        didSet { Keys.correctionSuggestions.write(correctionSuggestions, to: defaults) }
    }

    /// Keep the last dictations and their audio in the Run Log. On by default.
    public var keepRunLog: Bool {
        didSet { Keys.keepRunLog.write(keepRunLog, to: defaults) }
    }

    /// What the user chose for opening at login. The app registers it with the system. Off by default.
    public var launchAtLogin: Bool {
        didSet { Keys.launchAtLogin.write(launchAtLogin, to: defaults) }
    }

    /// The chosen microphone's unique identifier, or nil for the system default.
    public var microphoneID: String? {
        didSet { Keys.microphoneID.write(microphoneID, to: defaults) }
    }

    /// Record from a built-in or wired microphone when the system default is a Bluetooth one, so a headset stays out of
    /// its call profile (ARCHITECTURE.md, section 6, "Audio capture"). On by default.
    public var avoidBluetoothMicrophone: Bool {
        didSet { Keys.avoidBluetoothMicrophone.write(avoidBluetoothMicrophone, to: defaults) }
    }

    /// Setup has been finished once. Off by default.
    public var setupCompleted: Bool {
        didSet { Keys.setupCompleted.write(setupCompleted, to: defaults) }
    }

    /// Reads every setting from `defaults`, using each one's default where nothing usable is stored.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        holdToTalkShortcut = Keys.holdToTalkShortcut.read(from: defaults)
        tapToToggleShortcut = Keys.tapToToggleShortcut.read(from: defaults)
        pasteAgainShortcut = Keys.pasteAgainShortcut.read(from: defaults)
        restoreClipboard = Keys.restoreClipboard.read(from: defaults)
        spokenNumbers = Keys.spokenNumbers.read(from: defaults)
        spokenDelimiters = Keys.spokenDelimiters.read(from: defaults)
        pressEnterCommand = Keys.pressEnterCommand.read(from: defaults)
        doubleTap = Keys.doubleTap.read(from: defaults)
        promptTag = Keys.promptTag.read(from: defaults)
        correctionSuggestions = Keys.correctionSuggestions.read(from: defaults)
        keepRunLog = Keys.keepRunLog.read(from: defaults)
        launchAtLogin = Keys.launchAtLogin.read(from: defaults)
        microphoneID = Keys.microphoneID.read(from: defaults)
        avoidBluetoothMicrophone = Keys.avoidBluetoothMicrophone.read(from: defaults)
        setupCompleted = Keys.setupCompleted.read(from: defaults)
    }

    /// The shortcut bound to `action`, for screens that list the actions.
    public func shortcut(for action: ShortcutAction) -> ShortcutBinding? {
        switch action {
        case .holdToTalk: holdToTalkShortcut
        case .tapToToggle: tapToToggleShortcut
        case .pasteAgain: pasteAgainShortcut
        }
    }

    /// Binds `binding` to `action`, or removes the action's shortcut with nil. Whether a binding is allowed (not
    /// Escape, not another action's) is the shortcut recorder's decision; this only stores it.
    public func setShortcut(_ binding: ShortcutBinding?, for action: ShortcutAction) {
        switch action {
        case .holdToTalk: holdToTalkShortcut = binding
        case .tapToToggle: tapToToggleShortcut = binding
        case .pasteAgain: pasteAgainShortcut = binding
        }
    }
}

// MARK: - Keys

/// Every setting's stored name and default. Saved settings depend on these names, so they never change.
enum Keys {
    static let holdToTalkShortcut = CodableKey<ShortcutBinding?>("holdToTalkShortcut", default: .function)
    static let tapToToggleShortcut = CodableKey<ShortcutBinding?>("tapToToggleShortcut", default: nil)
    static let pasteAgainShortcut = CodableKey<ShortcutBinding?>("pasteAgainShortcut", default: nil)
    static let restoreClipboard = PlainKey("restoreClipboard", default: true)
    static let spokenNumbers = PlainKey("spokenNumbers", default: true)
    static let spokenDelimiters = PlainKey("spokenDelimiters", default: false)
    static let pressEnterCommand = PlainKey("pressEnterCommand", default: false)
    static let doubleTap = PlainKey<DoubleTapAction>("doubleTap", default: .handsFree)
    static let promptTag = PlainKey("promptTag", default: "[dictated]")
    static let correctionSuggestions = PlainKey("correctionSuggestions", default: true)
    static let keepRunLog = PlainKey("keepRunLog", default: true)
    static let launchAtLogin = PlainKey("launchAtLogin", default: false)
    static let microphoneID = PlainKey<String?>("microphoneID", default: nil)
    static let avoidBluetoothMicrophone = PlainKey("avoidBluetoothMicrophone", default: true)
    static let setupCompleted = PlainKey("setupCompleted", default: false)
}

/// A value `UserDefaults` stores as a property-list object of exactly this type.
protocol PlainValue: Sendable {
    /// The stored object as this type, or nil when it is missing or of another type.
    static func value(of object: Any?) -> Self?
    /// What `UserDefaults.set(_:forKey:)` receives; nil removes the key.
    var storedObject: Any? { get }
}

extension PlainValue {
    static func value(of object: Any?) -> Self? { object as? Self }
    var storedObject: Any? { self }
}

extension Bool: PlainValue {
    /// Only a stored Boolean: a number or the string "YES" written by hand is not one.
    static func value(of object: Any?) -> Bool? {
        guard let number = object as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

extension String: PlainValue {}

extension DoubleTapAction: PlainValue {
    /// Stored as its name, so the stored value reads the same whatever the cases are called in code. Any other
    /// value, including a name in another case, is not one.
    static func value(of object: Any?) -> DoubleTapAction? {
        switch object as? String {
        case "handsFree": .handsFree
        case "prompt": .prompt
        case "off": .off
        default: nil
        }
    }

    var storedObject: Any? {
        switch self {
        case .handsFree: "handsFree"
        case .prompt: "prompt"
        case .off: "off"
        }
    }
}

extension Optional: PlainValue where Wrapped: PlainValue {
    /// A stored value of the wrapped type is `.some`; anything else (including nothing) is not a value.
    static func value(of object: Any?) -> Wrapped?? {
        Wrapped.value(of: object).map { .some($0) }
    }

    var storedObject: Any? { self?.storedObject }
}

/// A setting stored as a plain property-list value.
struct PlainKey<Value: PlainValue>: Sendable {
    let name: String
    let defaultValue: Value

    init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }

    func read(from defaults: UserDefaults) -> Value {
        Value.value(of: defaults.object(forKey: name)) ?? defaultValue
    }

    func write(_ value: Value, to defaults: UserDefaults) {
        if let object = value.storedObject {
            defaults.set(object, forKey: name)
        } else {
            defaults.removeObject(forKey: name)
        }
    }
}

/// A setting stored as JSON data. An optional value is stored as JSON `null` when the user cleared it, which is
/// different from nothing stored (the default).
struct CodableKey<Value: Codable & Sendable>: Sendable {
    let name: String
    let defaultValue: Value

    init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }

    func read(from defaults: UserDefaults) -> Value {
        guard let data = defaults.data(forKey: name),
              let value = try? JSONDecoder().decode(Value.self, from: data) else { return defaultValue }
        return value
    }

    func write(_ value: Value, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: name)
    }
}
