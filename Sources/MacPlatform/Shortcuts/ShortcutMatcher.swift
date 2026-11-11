import DictationCore
import Foundation

/// Turns keyboard events into triggers (ARCHITECTURE.md, section 6, "Shortcuts"). A pure state machine: it is fed
/// one `KeyEvent` at a time and answers which triggers to deliver and whether the event tap should swallow the
/// event. `ShortcutMonitor` drives it from the real tap; tests drive it by hand.
///
/// The rules it keeps:
/// - A key binding consumes its own key-down, its repeats and its key-up, and always consumes the key-up of a
///   key-down it consumed, even if the bindings or the modifiers changed in between.
/// - A modifier-only binding consumes nothing. It matches when one of its keys goes down and leaves exactly its
///   keys down, with no other key held.
/// - A modifier-only hold that sees another key go down within `chordWindow` was the start of a chord:
///   `holdAbandoned`.
/// - A hold's release always belongs to the press that started it: the hold ends when its own key comes up,
///   whatever happened to the other modifiers.
/// - Auto-repeat never triggers anything; an action triggers again only after a fresh key-down.
/// - Escape, with any modifiers, is `cancelPressed`, and is consumed only if the handler says it cancelled
///   something. It never counts as a chord's second key, so Escape during a fresh hold cancels it
///   rather than abandoning it.
/// - While recording a binding for Settings, nothing triggers; the keys pressed are captured and consumed.
public struct ShortcutMatcher: Sendable {
    /// How soon after a modifier-only hold starts another key turns it into a chord.
    public static let chordWindow: TimeInterval = 0.3

    /// How a recording ended.
    public enum RecordingResult: Sendable, Equatable {
        case recorded(ShortcutBinding)
        /// Escape was pressed, or the recording was cancelled or interrupted.
        case cancelled
    }

    /// What to do with one event.
    public struct Response: Sendable, Equatable {
        /// Swallow the event: the app in front never sees it.
        public var consume: Bool
        /// Set when this event ended a recording.
        public var recording: RecordingResult?

        public init(consume: Bool, recording: RecordingResult? = nil) {
            self.consume = consume
            self.recording = recording
        }
    }

    public private(set) var bindings: [ShortcutAction: ShortcutBinding]

    /// Whether a Hold to Talk press is in progress.
    public var isHolding: Bool { hold != nil }
    /// Whether the next binding is being recorded.
    public var isRecording: Bool { recorder != nil }

    private struct Hold {
        enum Source { case key(UInt16), modifiers(Set<ModifierKey>) }
        var source: Source
        var start: TimeInterval
    }

    private struct Recorder {
        /// Modifier keys that went down while recording, and the most of them held at once.
        var pressed: Set<ModifierKey> = []
        var peak: Set<ModifierKey> = []
    }

    private var modifiers: Set<ModifierKey> = []
    /// Non-modifier keys seen going down and not yet up, so a modifier-only binding matches only on its own.
    private var keysDown: Set<UInt16> = []
    /// Keys whose key-down was consumed: their repeats and key-up are consumed too.
    private var consumedKeys: Set<UInt16> = []
    /// Modifier keys whose going down was consumed while recording: their release is consumed too.
    private var consumedModifiers: Set<ModifierKey> = []
    private var hold: Hold?
    private var recorder: Recorder?

    private static let order: [ShortcutAction] = [.holdToTalk, .tapToToggle, .pasteAgain]

    public init(bindings: [ShortcutAction: ShortcutBinding]) {
        self.bindings = bindings
    }

    /// Handles one event. `deliver` is called for each trigger, in order, and returns whether it did something
    /// (`TriggerHandling.handle`); only Escape's consumption depends on that answer.
    public mutating func handle(_ event: KeyEvent, deliver: (TriggerEvent) -> Bool) -> Response {
        switch event.kind {
        case .modifiersChanged: modifiersChanged(event, deliver)
        case .keyDown(let isRepeat): keyDown(event, isRepeat: isRepeat, deliver)
        case .keyUp: keyUp(event, deliver)
        }
    }

    /// Replaces the bindings. A hold in progress whose binding changed ends as `holdReleased(.interrupted)`; the
    /// key-ups of keys already consumed are still consumed.
    public mutating func setBindings(_ new: [ShortcutAction: ShortcutBinding]) -> [TriggerEvent] {
        let holdChanged = new[.holdToTalk] != bindings[.holdToTalk]
        bindings = new
        guard holdChanged, hold != nil else { return [] }
        hold = nil
        return [.holdReleased(.interrupted)]
    }

    /// The tap stopped seeing events for a while (the system disabled it, or secure input took the keyboard), so
    /// what it knew about keys being down may be stale. A hold in progress ends as `holdReleased(.interrupted)`
    /// and a recording is cancelled. Keys already consumed still have their key-ups consumed.
    public mutating func interrupt() -> [TriggerEvent] {
        recorder = nil
        keysDown = []
        modifiers = []
        guard hold != nil else { return [] }
        hold = nil
        return [.holdReleased(.interrupted)]
    }

    /// Starts recording the next binding: a key with the modifiers held with it, or a set of modifier keys
    /// pressed and then all released. Nothing triggers while recording. A hold in progress ends as
    /// `holdReleased(.interrupted)`, since its release could not be delivered.
    public mutating func startRecording() -> [TriggerEvent] {
        recorder = Recorder()
        guard hold != nil else { return [] }
        hold = nil
        return [.holdReleased(.interrupted)]
    }

    /// Stops recording without a result. Keys consumed so far still have their releases consumed.
    public mutating func cancelRecording() {
        recorder = nil
    }

    // MARK: - Events

    private mutating func keyDown(_ event: KeyEvent, isRepeat: Bool, _ deliver: (TriggerEvent) -> Bool) -> Response {
        let code = event.keyCode
        guard !isRepeat else {
            keysDown.insert(code)
            return Response(consume: consumedKeys.contains(code))
        }
        // A fresh key-down: whatever was remembered about an earlier press of this key is over.
        consumedKeys.remove(code)
        keysDown.insert(code)

        if recorder != nil {
            recorder = nil
            consumedKeys.insert(code)
            if code == KeyCode.escape { return Response(consume: true, recording: .cancelled) }
            return Response(consume: true, recording: .recorded(.key(code: code, modifiers: ModifierFlags(event.modifiers))))
        }

        if code == KeyCode.escape {
            let cancelled = deliver(.cancelPressed)
            if cancelled { consumedKeys.insert(code) }
            return Response(consume: cancelled)
        }

        if let hold, case .modifiers = hold.source, event.time - hold.start < Self.chordWindow {
            self.hold = nil
            _ = deliver(.holdAbandoned)
        }

        let flags = ModifierFlags(event.modifiers)
        guard let action = Self.order.first(where: { bindings[$0] == .key(code: code, modifiers: flags) }) else {
            return Response(consume: false)
        }
        consumedKeys.insert(code)
        switch action {
        case .holdToTalk:
            if hold == nil {
                hold = Hold(source: .key(code), start: event.time)
                _ = deliver(.holdPressed)
            }
        case .tapToToggle: _ = deliver(.togglePressed)
        case .pasteAgain: _ = deliver(.pasteAgainPressed)
        }
        return Response(consume: true)
    }

    private mutating func keyUp(_ event: KeyEvent, _ deliver: (TriggerEvent) -> Bool) -> Response {
        let code = event.keyCode
        keysDown.remove(code)
        let consume = consumedKeys.remove(code) != nil
        if let hold, case .key(let held) = hold.source, held == code {
            self.hold = nil
            _ = deliver(.holdReleased(.keyUp))
        }
        return Response(consume: consume)
    }

    private mutating func modifiersChanged(_ event: KeyEvent, _ deliver: (TriggerEvent) -> Bool) -> Response {
        let new = event.modifiers
        let added = new.subtracting(modifiers)
        let removed = modifiers.subtracting(new)
        modifiers = new

        // A release balances a press consumed while recording, even after the recording ended.
        var consume = !removed.isDisjoint(with: consumedModifiers)
        consumedModifiers.subtract(removed)

        if var recorder {
            recorder.pressed.formUnion(added)
            consumedModifiers.formUnion(added)
            consume = consume || !added.isEmpty
            let held = new.intersection(recorder.pressed)
            if held.count > recorder.peak.count { recorder.peak = held }
            if held.isEmpty, !recorder.peak.isEmpty {
                self.recorder = nil
                return Response(consume: consume, recording: .recorded(.modifiers(recorder.peak)))
            }
            self.recorder = recorder
            return Response(consume: consume)
        }
        consumedModifiers.subtract(added)

        if let hold, case .modifiers(let keys) = hold.source {
            if !removed.isDisjoint(with: keys) {
                self.hold = nil
                _ = deliver(.holdReleased(.keyUp))
            } else if !added.isEmpty, event.time - hold.start < Self.chordWindow {
                self.hold = nil
                _ = deliver(.holdAbandoned)
            }
        }

        guard !added.isEmpty, keysDown.isEmpty else { return Response(consume: consume) }
        for action in Self.order {
            guard case .modifiers(let keys)? = bindings[action], !keys.isEmpty, keys == new,
                  !keys.isDisjoint(with: added) else { continue }
            switch action {
            case .holdToTalk:
                if hold == nil {
                    hold = Hold(source: .modifiers(keys), start: event.time)
                    _ = deliver(.holdPressed)
                }
            case .tapToToggle: _ = deliver(.togglePressed)
            case .pasteAgain: _ = deliver(.pasteAgainPressed)
            }
        }
        return Response(consume: consume)
    }
}
