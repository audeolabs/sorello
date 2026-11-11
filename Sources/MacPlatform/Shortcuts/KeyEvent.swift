import CoreGraphics
import Foundation
import DictationCore

/// One keyboard event as the shortcut matcher sees it: what happened, to which key, which modifier keys are down
/// by physical key, and when. `ShortcutMonitor` makes these from the event tap's `CGEvent`s; tests make them by
/// hand.
public struct KeyEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A key went down. `isRepeat` marks the keyboard's auto-repeat while the key is held.
        case keyDown(isRepeat: Bool)
        case keyUp
        /// A modifier key went down or up. `keyCode` names it and `modifiers` is the state after the change.
        case modifiersChanged
    }

    public var kind: Kind
    public var keyCode: UInt16
    /// Every modifier key down at the time of the event, left and right distinguished.
    public var modifiers: Set<ModifierKey>
    /// Monotonic seconds on `SessionClock`'s timeline.
    public var time: TimeInterval

    public init(_ kind: Kind, keyCode: UInt16, modifiers: Set<ModifierKey> = [], time: TimeInterval) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.time = time
    }

    /// Normalizes an event tap's keyboard event. Returns nil for any event type other than key down, key up and
    /// flags changed.
    ///
    /// The side of each modifier comes from the device-dependent bits of `flags` (`NX_DEVICE…KEYMASK` in IOKit's
    /// `IOLLEvent.h`). When a keyboard sets only the generic bit, the sides known in `previous` stand and the key
    /// that changed flips its own; with nothing known, the left key is assumed. Fn is read only from flags-changed events: Apple
    /// keyboards also set the Fn bit on arrow, function and navigation key events while Fn is up, so for key down
    /// and up the Fn state in `previous` stands.
    public init?(type: CGEventType, keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool, time: TimeInterval,
                 previous: Set<ModifierKey>) {
        let kind: Kind
        switch type {
        case .keyDown: kind = .keyDown(isRepeat: isRepeat)
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .modifiersChanged
        default: return nil
        }
        var keys: Set<ModifierKey> = []
        for family in Self.families {
            let left = flags.rawValue & family.leftMask != 0
            let right = flags.rawValue & family.rightMask != 0
            if left { keys.insert(family.left) }
            if right { keys.insert(family.right) }
            guard !left, !right, flags.contains(family.generic) else { continue }
            // Only the generic bit: the sides already known stand, and the key that changed flips its own.
            var sides = previous.intersection([family.left, family.right])
            if kind == .modifiersChanged, let changed = KeyCode.modifierKey(for: keyCode),
               changed == family.left || changed == family.right {
                if sides.remove(changed) == nil { sides.insert(changed) }
                // The family is still down, so a key believed released must be the one held.
                if sides.isEmpty { sides = [changed] }
            }
            keys.formUnion(sides.isEmpty ? [family.left] : sides)
        }
        if kind == .modifiersChanged {
            if flags.contains(.maskSecondaryFn) { keys.insert(.function) }
        } else if previous.contains(.function) {
            keys.insert(.function)
        }
        self.init(kind, keyCode: keyCode, modifiers: keys, time: time)
    }

    private struct Family {
        let generic: CGEventFlags
        let left: ModifierKey
        let leftMask: UInt64
        let right: ModifierKey
        let rightMask: UInt64
    }

    // The device-dependent masks, from IOLLEvent.h.
    private static let families = [
        Family(generic: .maskControl, left: .leftControl, leftMask: 0x0000_0001, right: .rightControl, rightMask: 0x0000_2000),
        Family(generic: .maskShift, left: .leftShift, leftMask: 0x0000_0002, right: .rightShift, rightMask: 0x0000_0004),
        Family(generic: .maskCommand, left: .leftCommand, leftMask: 0x0000_0008, right: .rightCommand, rightMask: 0x0000_0010),
        Family(generic: .maskAlternate, left: .leftOption, leftMask: 0x0000_0020, right: .rightOption, rightMask: 0x0000_0040),
    ]
}
