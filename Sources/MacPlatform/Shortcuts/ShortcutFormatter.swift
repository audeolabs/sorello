import Carbon.HIToolbox
import DictationCore
import Foundation

/// Names keys by what they type on a keyboard layout. `ShortcutFormatter` asks one for the keys that have no fixed
/// name; tests inject a fixed one.
public protocol KeyboardLayout: Sendable {
    /// What the key types with no modifier, or nil if it types nothing.
    func characters(forKeyCode code: UInt16) -> String?
}

/// The display string for a binding, as the shortcut field, the menu and Setup show it.
///
/// Modifiers come in the system's order, fn first and then ⌃ ⌥ ⇧ ⌘. A key binding shows the key after its
/// modifiers ("⌥Space", "fn ⌘K"); a modifier-only binding names each key, with its side where the side matters
/// ("fn", "Right ⌥", "Left ⌃ Left ⌥"). Keys that type nothing have fixed names (Space, Return, F1 to F20, the
/// arrows); every other key is named by what it types on `layout`, so it reads "Z" on a German keyboard where a US
/// one would read "Y".
public struct ShortcutFormatter: Sendable {
    public let layout: any KeyboardLayout

    public init(layout: any KeyboardLayout) {
        self.layout = layout
    }

    public func string(for binding: ShortcutBinding) -> String {
        switch binding {
        case .key(let code, let modifiers):
            let glyphs = Self.glyphOrder.filter { modifiers.contains($0.flag) }.map(\.glyph).joined()
            let prefix = modifiers.contains(.function) ? "fn " : ""
            return prefix + glyphs + keyName(code)
        case .modifiers(let keys):
            return Self.keyOrder.filter(keys.contains).map(Self.name(of:)).joined(separator: " ")
        }
    }

    /// The name of one key, on its own.
    public func keyName(_ code: UInt16) -> String {
        if let fixed = KeyCode.fixedName(for: code) { return fixed }
        if let modifier = KeyCode.modifierKey(for: code) { return Self.name(of: modifier) }
        if let typed = layout.characters(forKeyCode: code) {
            let visible = typed.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            if !visible.isEmpty { return visible.uppercased() }
        }
        return String(localized: "Key \(code)")
    }

    private static let glyphOrder: [(flag: ModifierFlags, glyph: String)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]

    private static let keyOrder: [ModifierKey] = [
        .function, .leftControl, .rightControl, .leftOption, .rightOption, .leftShift, .rightShift, .leftCommand,
        .rightCommand,
    ]

    private static func name(of key: ModifierKey) -> String {
        switch key {
        case .function: "fn"
        case .leftControl: String(localized: "Left ⌃")
        case .rightControl: String(localized: "Right ⌃")
        case .leftOption: String(localized: "Left ⌥")
        case .rightOption: String(localized: "Right ⌥")
        case .leftShift: String(localized: "Left ⇧")
        case .rightShift: String(localized: "Right ⇧")
        case .leftCommand: String(localized: "Left ⌘")
        case .rightCommand: String(localized: "Right ⌘")
        }
    }
}

/// A keyboard layout's key map, copied once from the Text Input Sources service so it can be read on any thread.
public struct KeyboardLayoutSnapshot: KeyboardLayout {
    private let layoutData: Data?

    /// The layout the user is typing with now, or the ASCII-capable one if the current input source has no key
    /// map (some input methods). Text Input Sources must be asked on the main thread.
    @MainActor
    public static func current() -> KeyboardLayoutSnapshot {
        let current = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        if let current, let data = layoutData(of: current) { return KeyboardLayoutSnapshot(layoutData: data) }
        let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        return KeyboardLayoutSnapshot(layoutData: ascii.flatMap(layoutData(of:)))
    }

    /// An installed layout by its input source identifier, such as `com.apple.keylayout.German`, or nil if there
    /// is no such layout.
    @MainActor
    public init?(inputSourceID: String) {
        let filter = [kTISPropertyInputSourceID as String: inputSourceID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first, let data = Self.layoutData(of: source)
        else { return nil }
        self.init(layoutData: data)
    }

    private init(layoutData: Data?) {
        self.layoutData = layoutData
    }

    private static func layoutData(of source: TISInputSource) -> Data? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    public func characters(forKeyCode code: UInt16) -> String? {
        guard let layoutData else { return nil }
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self), code, UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
