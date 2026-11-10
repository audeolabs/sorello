import DictationCore
import MacPlatform
import Persistence
import SorelloUI

// Shortcuts as the settings store them, the monitor takes them and the windows show them (ARCHITECTURE.md, section 6,
// "Shortcuts"). SorelloUI never sees a binding: each becomes a `KeyCombo`, its key named through the current keyboard
// layout by MacPlatform's formatter.

extension ShortcutKind {
    /// The window's name for an action.
    init(_ action: ShortcutAction) {
        switch action {
        case .holdToTalk: self = .holdToTalk
        case .tapToToggle: self = .tapToToggle
        case .pasteAgain: self = .pasteAgain
        }
    }

    /// The action this recorder or row is for.
    var action: ShortcutAction {
        switch self {
        case .holdToTalk: .holdToTalk
        case .tapToToggle: .tapToToggle
        case .pasteAgain: .pasteAgain
        }
    }
}

extension SettingsStore {
    /// Every action that has a shortcut, as the monitor takes them. An action the user cleared is absent.
    var shortcutBindings: [ShortcutAction: ShortcutBinding] {
        var bindings: [ShortcutAction: ShortcutBinding] = [:]
        for action in ShortcutAction.allCases {
            if let binding = shortcut(for: action) { bindings[action] = binding }
        }
        return bindings
    }
}

extension KeyCombo {
    /// A binding as key caps: a key binding's modifiers have no side, a modifier-only binding names each key's side.
    init(_ binding: ShortcutBinding, formatter: ShortcutFormatter) {
        switch binding {
        case .key(let code, let modifiers):
            var caps: [ModifierCap] = []
            if modifiers.contains(.function) { caps.append(.function) }
            if modifiers.contains(.control) { caps.append(.control(.either)) }
            if modifiers.contains(.option) { caps.append(.option(.either)) }
            if modifiers.contains(.shift) { caps.append(.shift(.either)) }
            if modifiers.contains(.command) { caps.append(.command(.either)) }
            self.init(modifiers: caps, key: KeyName(label: formatter.keyName(code)))
        case .modifiers(let keys):
            self.init(modifiers: keys.map(ModifierCap.init))
        }
    }

    /// Each action's shortcut, for the menu panel; an action without one is absent and shows "Not set".
    static func all(_ bindings: [ShortcutAction: ShortcutBinding],
                    formatter: ShortcutFormatter) -> [ShortcutKind: KeyCombo] {
        var combos: [ShortcutKind: KeyCombo] = [:]
        for (action, binding) in bindings { combos[ShortcutKind(action)] = KeyCombo(binding, formatter: formatter) }
        return combos
    }
}

extension ModifierCap {
    /// One physical modifier key, with its side.
    init(_ key: ModifierKey) {
        switch key {
        case .function: self = .function
        case .leftControl: self = .control(.left)
        case .rightControl: self = .control(.right)
        case .leftOption: self = .option(.left)
        case .rightOption: self = .option(.right)
        case .leftShift: self = .shift(.left)
        case .rightShift: self = .shift(.right)
        case .leftCommand: self = .command(.left)
        case .rightCommand: self = .command(.right)
        }
    }
}

extension ShortcutRefusal {
    /// Why the recorder's capture cannot be saved, in the window's words.
    init(_ problem: ShortcutValidation.Problem) {
        switch problem {
        case .empty: self = .empty
        case .escape: self = .escape
        case .typingKey: self = .typingKey
        case .usedBy(let other): self = .alreadyUsed(by: ShortcutKind(other))
        }
    }
}
