import Carbon.HIToolbox
import DictationCore

/// Virtual key codes the shortcut code names, from Carbon's `Events.h` (`kVK_…`). A virtual key code is a position
/// on the keyboard, not a character: the same code types "Y" on a US layout and "Z" on a German one, which is why a
/// binding stores the code and `ShortcutFormatter` asks the current layout for its name.
public enum KeyCode {
    public static let escape = UInt16(kVK_Escape)
    public static let space = UInt16(kVK_Space)
    public static let returnKey = UInt16(kVK_Return)
    public static let tab = UInt16(kVK_Tab)
    public static let delete = UInt16(kVK_Delete)
    public static let forwardDelete = UInt16(kVK_ForwardDelete)
    public static let function = UInt16(kVK_Function)

    /// The physical modifier key a code belongs to, or nil for any other key.
    public static func modifierKey(for code: UInt16) -> ModifierKey? {
        switch Int(code) {
        case kVK_Command: .leftCommand
        case kVK_RightCommand: .rightCommand
        case kVK_Option: .leftOption
        case kVK_RightOption: .rightOption
        case kVK_Control: .leftControl
        case kVK_RightControl: .rightControl
        case kVK_Shift: .leftShift
        case kVK_RightShift: .rightShift
        case kVK_Function: .function
        default: nil
        }
    }

    /// Keys that type a character or edit text when pressed alone: letters, digits, punctuation, the keypad, Space,
    /// Return, Tab, both Deletes, the arrows and the other navigation keys. A shortcut made of one of these with no
    /// modifier would take the key away from typing.
    public static func typesOrEdits(_ code: UInt16) -> Bool {
        typingKeys.contains(Int(code))
    }

    private static let typingKeys: Set<Int> = [
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I,
        kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
        kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
        kVK_ANSI_9,
        kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_RightBracket, kVK_ANSI_LeftBracket, kVK_ANSI_Quote,
        kVK_ANSI_Semicolon, kVK_ANSI_Backslash, kVK_ANSI_Comma, kVK_ANSI_Slash, kVK_ANSI_Period, kVK_ANSI_Grave,
        kVK_ISO_Section, kVK_JIS_Yen, kVK_JIS_Underscore, kVK_JIS_KeypadComma,
        kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
        kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9, kVK_ANSI_KeypadDecimal,
        kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadMinus,
        kVK_ANSI_KeypadEquals, kVK_ANSI_KeypadEnter, kVK_ANSI_KeypadClear,
        kVK_Space, kVK_Return, kVK_Tab, kVK_Delete, kVK_ForwardDelete,
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
    ]

    /// The name of a key that types nothing, or whose character would not say which key it is, regardless of the
    /// keyboard layout. Nil for keys whose name comes from the layout.
    static func fixedName(for code: UInt16) -> String? {
        switch Int(code) {
        case kVK_Space: String(localized: "Space")
        case kVK_Return: String(localized: "Return")
        case kVK_ANSI_KeypadEnter: String(localized: "Enter")
        case kVK_Tab: String(localized: "Tab")
        case kVK_Delete: String(localized: "Delete")
        case kVK_ForwardDelete: String(localized: "Forward Delete")
        case kVK_Escape: String(localized: "Escape")
        case kVK_ANSI_KeypadClear: String(localized: "Clear")
        case kVK_Help: String(localized: "Help")
        case kVK_Home: String(localized: "Home")
        case kVK_End: String(localized: "End")
        case kVK_PageUp: String(localized: "Page Up")
        case kVK_PageDown: String(localized: "Page Down")
        case kVK_CapsLock: String(localized: "Caps Lock")
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_VolumeUp: String(localized: "Volume Up")
        case kVK_VolumeDown: String(localized: "Volume Down")
        case kVK_Mute: String(localized: "Mute")
        case kVK_JIS_Eisu: "英数"
        case kVK_JIS_Kana: "かな"
        case kVK_ContextualMenu: String(localized: "Menu")
        default: functionKeyNames[Int(code)].map { "F\($0)" }
        }
    }

    private static let functionKeyNames: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8, kVK_F9: 9,
        kVK_F10: 10, kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17,
        kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
    ]
}

extension ModifierFlags {
    /// The sideless flags of a set of physical modifier keys: Left ⌘ and Right ⌘ are both `command`.
    public init(_ keys: Set<ModifierKey>) {
        var flags: ModifierFlags = []
        for key in keys {
            switch key {
            case .leftCommand, .rightCommand: flags.insert(.command)
            case .leftOption, .rightOption: flags.insert(.option)
            case .leftControl, .rightControl: flags.insert(.control)
            case .leftShift, .rightShift: flags.insert(.shift)
            case .function: flags.insert(.function)
            }
        }
        self = flags
    }
}
