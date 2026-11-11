import CoreGraphics
import DictationCore

/// The key code the inserter adds to the ones the shortcuts name.
extension KeyCode {
    /// The key labelled V on an ANSI keyboard: the paste key when the layout cannot be read.
    public static let ansiV: UInt16 = 0x09
}

/// Posting keys into the app in front, and the keyboard state that decides whether that is safe. A seam so the
/// inserter can be tested without ever posting a real key.
public protocol KeyPoster: Sendable {
    /// Whether this process may post keyboard events (Accessibility). Only reads the state; never prompts.
    func mayPost() -> Bool
    /// Which of Command, Option, Control and Shift are physically held down now.
    func modifiersDown() -> ModifierFlags
    /// Posts one key down and up with exactly `modifiers` held. Returns false, having posted nothing, when the events
    /// could not be made.
    func post(key: UInt16, modifiers: ModifierFlags) -> Bool
}

/// A `KeyPoster` over Core Graphics events. Every event it posts carries `SyntheticEvents.tag` as its source user
/// data, so Sorello's own shortcut tap ignores it.
public struct SystemKeyPoster: KeyPoster {
    /// A poster with no state of its own.
    public init() {}

    public func mayPost() -> Bool { CGPreflightPostEventAccess() }

    public func modifiersDown() -> ModifierFlags {
        let flags = CGEventSource.flagsState(.hidSystemState)
        var down: ModifierFlags = []
        if flags.contains(.maskCommand) { down.insert(.command) }
        if flags.contains(.maskAlternate) { down.insert(.option) }
        if flags.contains(.maskControl) { down.insert(.control) }
        if flags.contains(.maskShift) { down.insert(.shift) }
        return down
    }

    public func post(key: UInt16, modifiers: ModifierFlags) -> Bool {
        guard let (down, up) = Self.events(key: key, modifiers: modifiers) else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// The key-down and key-up events `post` sends, tagged and carrying only `modifiers`, whatever is physically
    /// held. Separate from posting so the events can be checked without sending them anywhere.
    public static func events(key: UInt16, modifiers: ModifierFlags) -> (down: CGEvent, up: CGEvent)? {
        // A private source keeps the physical keyboard's state out of the events' flags.
        let source = CGEventSource(stateID: .privateState)
        source?.userData = SyntheticEvents.tag
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return nil }
        let flags = cgFlags(modifiers)
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvents.tag)
        }
        return (down, up)
    }

    private static func cgFlags(_ modifiers: ModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }
}
