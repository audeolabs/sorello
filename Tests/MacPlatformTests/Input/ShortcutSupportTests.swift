import Carbon.HIToolbox
import CoreGraphics
import DictationCore
import MacPlatform
import Testing

@Suite("Shortcut validation")
struct ShortcutValidationTests {
    private func problem(_ binding: ShortcutBinding, for action: ShortcutAction = .tapToToggle,
                         among bindings: [ShortcutAction: ShortcutBinding] = [:]) -> ShortcutValidation.Problem? {
        ShortcutValidation.problem(with: binding, for: action, among: bindings)
    }

    @Test("An empty modifier set is refused")
    func empty() {
        #expect(problem(.modifiers([])) == .empty)
    }

    @Test("Escape is refused with or without modifiers")
    func escape() {
        #expect(problem(.key(code: KeyCode.escape, modifiers: [])) == .escape)
        #expect(problem(.key(code: KeyCode.escape, modifiers: [.command])) == .escape)
    }

    @Test("Bare typing keys are refused", arguments: [
        kVK_ANSI_A, kVK_ANSI_Z, kVK_ANSI_5, kVK_ANSI_Slash, kVK_Space, kVK_Return, kVK_Tab, kVK_Delete,
        kVK_ForwardDelete, kVK_LeftArrow, kVK_UpArrow, kVK_ANSI_Keypad3, kVK_ANSI_KeypadEnter, kVK_Home,
    ])
    func bareTypingKey(code: Int) {
        #expect(problem(.key(code: UInt16(code), modifiers: [])) == .typingKey)
        #expect(problem(.key(code: UInt16(code), modifiers: .shift)) == .typingKey, "Shift alone still types")
        #expect(problem(.key(code: UInt16(code), modifiers: .option)) == nil)
        #expect(problem(.key(code: UInt16(code), modifiers: .function)) == nil)
    }

    @Test("Keys that type nothing may be bound alone")
    func bareNonTypingKey() {
        #expect(problem(.key(code: UInt16(kVK_F5), modifiers: [])) == nil)
        #expect(problem(.key(code: UInt16(kVK_F19), modifiers: [])) == nil)
    }

    @Test("A binding another action has is refused; the action's own is not")
    func duplicate() {
        let bindings: [ShortcutAction: ShortcutBinding] = [.holdToTalk: .function,
                                                          .tapToToggle: .modifiers([.rightOption])]
        #expect(problem(.function, for: .tapToToggle, among: bindings) == .usedBy(.holdToTalk))
        #expect(problem(.function, for: .pasteAgain, among: bindings) == .usedBy(.holdToTalk))
        #expect(problem(.modifiers([.rightOption]), for: .tapToToggle, among: bindings) == nil)
        #expect(problem(.modifiers([.leftOption]), for: .pasteAgain, among: bindings) == nil)
    }
}

/// A US-like layout with a German twist, so a test can tell the layout was asked.
private struct FixedLayout: KeyboardLayout {
    func characters(forKeyCode code: UInt16) -> String? {
        switch Int(code) {
        case kVK_ANSI_K: "k"
        case kVK_ANSI_Y: "z"
        case kVK_ANSI_Semicolon: "ö"
        case kVK_ANSI_Grave: "\u{10}"
        default: nil
        }
    }
}

@Suite("Shortcut formatter")
struct ShortcutFormatterTests {
    private let formatter = ShortcutFormatter(layout: FixedLayout())

    @Test("Modifier-only bindings name each key, with its side")
    func modifierOnly() {
        #expect(formatter.string(for: .function) == "fn")
        #expect(formatter.string(for: .modifiers([.rightOption])) == "Right ⌥")
        #expect(formatter.string(for: .modifiers([.leftCommand, .leftControl, .function])) == "fn Left ⌃ Left ⌘")
        #expect(formatter.string(for: .modifiers([.rightShift, .leftShift])) == "Left ⇧ Right ⇧")
    }

    @Test("Key bindings show modifiers in the system's order without sides, then the key")
    func keyBindings() {
        let all: ModifierFlags = [.command, .shift, .option, .control]
        #expect(formatter.string(for: .key(code: UInt16(kVK_ANSI_K), modifiers: all)) == "⌃⌥⇧⌘K")
        #expect(formatter.string(for: .key(code: UInt16(kVK_Space), modifiers: .option)) == "⌥Space")
        #expect(formatter.string(for: .key(code: UInt16(kVK_ANSI_K), modifiers: [.function, .command])) == "fn ⌘K")
    }

    @Test("Keys that type nothing have fixed names")
    func fixedNames() {
        #expect(formatter.keyName(UInt16(kVK_Return)) == "Return")
        #expect(formatter.keyName(UInt16(kVK_F1)) == "F1")
        #expect(formatter.keyName(UInt16(kVK_F20)) == "F20")
        #expect(formatter.keyName(UInt16(kVK_LeftArrow)) == "←")
        #expect(formatter.keyName(UInt16(kVK_DownArrow)) == "↓")
        #expect(formatter.keyName(UInt16(kVK_PageDown)) == "Page Down")
    }

    @Test("Other keys are named by the layout, upper-cased")
    func layoutNames() {
        #expect(formatter.keyName(UInt16(kVK_ANSI_Y)) == "Z")
        #expect(formatter.keyName(UInt16(kVK_ANSI_Semicolon)) == "Ö")
    }

    @Test("A key the layout cannot name visibly falls back to its code")
    func unnamed() {
        #expect(formatter.keyName(UInt16(kVK_ANSI_Grave)) == "Key 50")
        #expect(formatter.keyName(UInt16(kVK_ANSI_Q)) == "Key 12")
    }

    @Test("Installed layouts name keys by what they type", .enabled { await hasLayout("com.apple.keylayout.German") })
    @MainActor
    func systemLayouts() throws {
        let us = try #require(KeyboardLayoutSnapshot(inputSourceID: "com.apple.keylayout.US"))
        let german = try #require(KeyboardLayoutSnapshot(inputSourceID: "com.apple.keylayout.German"))
        #expect(ShortcutFormatter(layout: us).keyName(UInt16(kVK_ANSI_Y)) == "Y")
        #expect(ShortcutFormatter(layout: german).keyName(UInt16(kVK_ANSI_Y)) == "Z")
        #expect(ShortcutFormatter(layout: german).keyName(UInt16(kVK_ANSI_Semicolon)) == "Ö")
        #expect(KeyboardLayoutSnapshot(inputSourceID: "com.example.no-such-layout") == nil)
    }
}

@MainActor
private func hasLayout(_ id: String) -> Bool {
    KeyboardLayoutSnapshot(inputSourceID: id) != nil
}

@Suite("Reading CGEvent modifier flags")
struct KeyEventNormalizationTests {
    // Device-dependent bits, from IOLLEvent.h.
    private let leftCommand: UInt64 = 0x08, rightCommand: UInt64 = 0x10, rightOption: UInt64 = 0x40
    private let leftShift: UInt64 = 0x02

    private func event(_ type: CGEventType, _ code: Int, _ flags: CGEventFlags,
                       previous: Set<ModifierKey> = []) -> KeyEvent? {
        KeyEvent(type: type, keyCode: UInt16(code), flags: flags, isRepeat: false, time: 5, previous: previous)
    }

    @Test("Sides come from the device bits")
    func sides() {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | leftCommand | rightCommand
                                 | CGEventFlags.maskAlternate.rawValue | rightOption)
        let changed = event(.flagsChanged, kVK_RightOption, flags)
        #expect(changed?.kind == .modifiersChanged)
        #expect(changed?.modifiers == [.leftCommand, .rightCommand, .rightOption])
        #expect(changed?.time == 5)
    }

    @Test("Without device bits, the key that changed gives the side, then what was known")
    func genericOnly() {
        let flags = CGEventFlags.maskShift
        #expect(event(.flagsChanged, kVK_RightShift, flags)?.modifiers == [.rightShift])
        #expect(event(.keyDown, kVK_ANSI_A, flags, previous: [.rightShift])?.modifiers == [.rightShift])
        #expect(event(.keyDown, kVK_ANSI_A, flags)?.modifiers == [.leftShift])
    }

    @Test("Fn is read from flags-changed events only")
    func function() {
        #expect(event(.flagsChanged, kVK_Function, .maskSecondaryFn)?.modifiers == [.function])
        #expect(event(.flagsChanged, kVK_Function, [])?.modifiers == [])
        // Arrow keys carry the Fn bit while Fn is up.
        #expect(event(.keyDown, kVK_LeftArrow, .maskSecondaryFn)?.modifiers == [])
        #expect(event(.keyDown, kVK_LeftArrow, [], previous: [.function])?.modifiers == [.function])
        let shift = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | leftShift
                                 | CGEventFlags.maskSecondaryFn.rawValue)
        #expect(event(.flagsChanged, kVK_Shift, shift)?.modifiers == [.leftShift, .function])
    }

    @Test("Key down, repeat and up are told apart; other event types are not key events")
    func kinds() {
        #expect(event(.keyDown, kVK_ANSI_A, [])?.kind == .keyDown(isRepeat: false))
        let repeated = KeyEvent(type: .keyDown, keyCode: 0, flags: [], isRepeat: true, time: 0, previous: [])
        #expect(repeated?.kind == .keyDown(isRepeat: true))
        #expect(event(.keyUp, kVK_ANSI_A, [])?.kind == .keyUp)
        #expect(event(.leftMouseDown, 0, []) == nil)
        #expect(event(.tapDisabledByTimeout, 0, []) == nil)
    }
}
