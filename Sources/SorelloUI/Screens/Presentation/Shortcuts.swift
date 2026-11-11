import Foundation

// How shortcuts are shown: as key caps, in a sentence and to VoiceOver. SorelloUI does not see the shortcut
// adapter's bindings; the app layer turns each binding into a `KeyCombo`, naming its key through the current
// keyboard layout, and these types decide how it reads.

/// Which physical key of a pair a modifier is, when it matters.
nonisolated public enum KeySide: Hashable, Sendable {
    /// Either key: the shortcut is a key with modifiers ("⌥Space").
    case either
    case left
    case right
}

/// One modifier key in a shortcut.
nonisolated public enum ModifierCap: Hashable, Sendable {
    case function
    case control(KeySide)
    case option(KeySide)
    case shift(KeySide)
    case command(KeySide)

    /// The order the Mac writes modifiers in: fn, then ⌃ ⌥ ⇧ ⌘, the left key before the right.
    var order: Int {
        switch self {
        case .function: 0
        case .control(let side): 10 + side.order
        case .option(let side): 20 + side.order
        case .shift(let side): 30 + side.order
        case .command(let side): 40 + side.order
        }
    }

    var side: KeySide {
        switch self {
        case .function: .either
        case .control(let side), .option(let side), .shift(let side), .command(let side): side
        }
    }

    /// The glyph on the key cap.
    var symbol: String {
        switch self {
        case .function: "fn"
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }

    /// The key's name, for VoiceOver.
    var spokenName: String {
        switch self {
        case .function: String(localized: "Function")
        case .control: String(localized: "Control")
        case .option: String(localized: "Option")
        case .shift: String(localized: "Shift")
        case .command: String(localized: "Command")
        }
    }
}

nonisolated extension KeySide {
    var order: Int {
        switch self {
        case .either: 0
        case .left: 1
        case .right: 2
        }
    }
}

/// A key that is not a modifier, named the way the current keyboard layout names it.
nonisolated public struct KeyName: Hashable, Sendable {
    /// What the key cap shows: "D", "Space", "F5", "→".
    public var label: String
    /// What VoiceOver says: "D", "Space", "F5", "Right Arrow".
    public var spoken: String

    /// A key shown as `label` and spoken as `spoken`, or as `label` without it.
    public init(label: String, spoken: String? = nil) {
        self.label = label
        self.spoken = spoken ?? label
    }
}

/// A shortcut as it is shown: modifiers in the Mac's order, then at most one key.
nonisolated public struct KeyCombo: Hashable, Sendable {
    /// Sorted into the Mac's order, without repeats.
    public let modifiers: [ModifierCap]
    /// The key that is not a modifier, if any.
    public let key: KeyName?

    /// A shortcut of `modifiers` and `key`, in any order; repeats are dropped.
    public init(modifiers: [ModifierCap], key: KeyName? = nil) {
        var seen = Set<ModifierCap>()
        self.modifiers = modifiers.filter { seen.insert($0).inserted }.sorted { $0.order < $1.order }
        self.key = key
    }

    /// The default Hold to Talk shortcut.
    public static let function = KeyCombo(modifiers: [.function])

    /// One key cap.
    public struct Cap: Hashable, Sendable {
        /// The glyph or key name.
        public var symbol: String
        /// "left" or "right" for a modifier that names its side, shown small beside the glyph.
        public var side: String?
    }

    /// The key caps, in order.
    public var caps: [Cap] {
        modifiers.map { Cap(symbol: $0.symbol, side: Self.sideWord($0.side)) } + (key.map { [Cap(symbol: $0.label)] } ?? [])
    }

    /// The shortcut inside a sentence: "fn", "Right ⌥", "⌃⌥Space".
    public var inlineLabel: String {
        let sided = modifiers.count == 1 && key == nil && modifiers[0].side != .either
        if sided, let side = Self.sideWord(modifiers[0].side) {
            return "\(side.prefix(1).uppercased())\(side.dropFirst()) \(modifiers[0].symbol)"
        }
        return modifiers.map(\.symbol).joined() + (key?.label ?? "")
    }

    /// The shortcut for VoiceOver: "Function", "Right Option", "Control Option Space".
    public var spokenLabel: String {
        let words = modifiers.map { modifier -> String in
            switch modifier.side {
            case .either: modifier.spokenName
            case .left: String(localized: "Left \(modifier.spokenName)")
            case .right: String(localized: "Right \(modifier.spokenName)")
            }
        } + (key.map { [$0.spoken] } ?? [])
        return words.joined(separator: " ")
    }

    private static func sideWord(_ side: KeySide) -> String? {
        switch side {
        case .either: nil
        case .left: String(localized: "left")
        case .right: String(localized: "right")
        }
    }
}

/// The three actions a shortcut can be bound to.
nonisolated public enum ShortcutKind: CaseIterable, Hashable, Sendable {
    case holdToTalk
    case tapToToggle
    case pasteAgain

    /// The action's name.
    public var title: String {
        switch self {
        case .holdToTalk: String(localized: "Hold to Talk")
        case .tapToToggle: String(localized: "Tap to Toggle")
        case .pasteAgain: String(localized: "Paste Again")
        }
    }


    /// Hold to Talk always has a shortcut; the other two can be left unset.
    public var canBeUnset: Bool { self != .holdToTalk }
}

/// Why the recorder refused what was pressed (ARCHITECTURE.md, section 6, "Shortcuts").
nonisolated public enum ShortcutRefusal: Equatable, Sendable {
    /// Nothing usable was pressed.
    case empty
    /// Escape cancels a dictation.
    case escape
    /// A key that types, without a modifier.
    case typingKey
    /// Another action already uses it.
    case alreadyUsed(by: ShortcutKind)

    /// The inline message under the recorder.
    public var message: String {
        switch self {
        case .empty: String(localized: "Press a key with modifiers, or modifier keys alone.")
        case .escape: String(localized: "Escape cancels a dictation, so it can’t be a shortcut.")
        case .typingKey: String(localized: "Add a modifier such as ⌃ or ⌥. A key that types can’t be a shortcut alone.")
        case .alreadyUsed(let other): String(localized: "\(other.title) already uses these keys.")
        }
    }
}

/// One shortcut recorder: what is bound, whether it is listening for keys, and the last refusal.
nonisolated public struct ShortcutRecorderState: Equatable, Sendable {
    /// Nil when the action has no shortcut.
    public var keys: KeyCombo?
    /// Waiting for the next key or set of modifiers. While it records, no shortcut triggers anything.
    public var isRecording: Bool
    /// Shown under the recorder until the next attempt.
    public var refusal: ShortcutRefusal?

    /// A recorder showing `keys`.
    public init(keys: KeyCombo?, isRecording: Bool = false, refusal: ShortcutRefusal? = nil) {
        self.keys = keys
        self.isRecording = isRecording
        self.refusal = refusal
    }
}
