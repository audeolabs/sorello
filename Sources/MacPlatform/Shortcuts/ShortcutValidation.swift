import DictationCore

/// Whether a binding may be given to an action (ARCHITECTURE.md, section 6, "Shortcuts"). Settings asks before it
/// saves what the recorder captured, and shows the problem instead of saving.
public enum ShortcutValidation {
    public enum Problem: Error, Sendable, Equatable {
        /// A modifier-only binding with no keys.
        case empty
        /// Escape is reserved for cancelling a dictation.
        case escape
        /// A key that types or edits text, with no modifier or only Shift: it would take the key away from typing.
        case typingKey
        /// Another action already has exactly this binding.
        case usedBy(ShortcutAction)
    }

    /// The reason `binding` cannot be given to `action` when the other actions have `bindings`, or nil if it can.
    /// `action`'s own entry in `bindings` is ignored, so re-saving a binding unchanged is allowed.
    public static func problem(with binding: ShortcutBinding, for action: ShortcutAction,
                               among bindings: [ShortcutAction: ShortcutBinding]) -> Problem? {
        switch binding {
        case .modifiers(let keys):
            if keys.isEmpty { return .empty }
        case .key(let code, let modifiers):
            if code == KeyCode.escape { return .escape }
            if modifiers.isSubset(of: .shift), KeyCode.typesOrEdits(code) { return .typingKey }
        }
        let other = ShortcutAction.allCases.first { $0 != action && bindings[$0] == binding }
        return other.map(Problem.usedBy)
    }
}
