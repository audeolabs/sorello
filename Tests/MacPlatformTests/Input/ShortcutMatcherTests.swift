import Carbon.HIToolbox
import DictationCore
import MacPlatform
import Testing

/// Drives a matcher the way the event tap does and keeps what it delivered.
private struct Keyboard {
    var matcher: ShortcutMatcher
    var delivered: [TriggerEvent] = []
    /// What the handler answers for each trigger; Escape's consumption depends on it.
    var handled = true
    var modifiers: Set<ModifierKey> = []
    var time: TimeInterval = 100

    init(_ bindings: [ShortcutAction: ShortcutBinding]) {
        matcher = ShortcutMatcher(bindings: bindings)
    }

    mutating func send(_ event: KeyEvent) -> ShortcutMatcher.Response {
        let handled = handled
        var heard: [TriggerEvent] = []
        let response = matcher.handle(event) { heard.append($0); return handled }
        delivered += heard
        return response
    }

    /// Takes what was delivered since the last call.
    mutating func take() -> [TriggerEvent] {
        defer { delivered = [] }
        return delivered
    }

    mutating func advance(_ seconds: TimeInterval) { time += seconds }

    @discardableResult
    mutating func press(_ key: ModifierKey) -> ShortcutMatcher.Response {
        modifiers.insert(key)
        return send(KeyEvent(.modifiersChanged, keyCode: Self.code(key), modifiers: modifiers, time: time))
    }

    @discardableResult
    mutating func release(_ key: ModifierKey) -> ShortcutMatcher.Response {
        modifiers.remove(key)
        return send(KeyEvent(.modifiersChanged, keyCode: Self.code(key), modifiers: modifiers, time: time))
    }

    @discardableResult
    mutating func down(_ code: Int, repeat isRepeat: Bool = false) -> ShortcutMatcher.Response {
        send(KeyEvent(.keyDown(isRepeat: isRepeat), keyCode: UInt16(code), modifiers: modifiers, time: time))
    }

    @discardableResult
    mutating func up(_ code: Int) -> ShortcutMatcher.Response {
        send(KeyEvent(.keyUp, keyCode: UInt16(code), modifiers: modifiers, time: time))
    }

    static func code(_ key: ModifierKey) -> UInt16 {
        let codes: [ModifierKey: Int] = [
            .leftCommand: kVK_Command, .rightCommand: kVK_RightCommand, .leftOption: kVK_Option,
            .rightOption: kVK_RightOption, .leftControl: kVK_Control, .rightControl: kVK_RightControl,
            .leftShift: kVK_Shift, .rightShift: kVK_RightShift, .function: kVK_Function,
        ]
        return UInt16(codes[key] ?? 0)
    }
}

private let optionSpace = ShortcutBinding.key(code: UInt16(kVK_Space), modifiers: .option)
private let controlT = ShortcutBinding.key(code: UInt16(kVK_ANSI_T), modifiers: .control)
private let commandShiftV = ShortcutBinding.key(code: UInt16(kVK_ANSI_V), modifiers: [.command, .shift])

@Suite("Modifier-only Hold to Talk")
struct ModifierHoldTests {
    @Test("Fn down and up is a hold, and consumes nothing")
    func pressAndRelease() {
        var keys = Keyboard([.holdToTalk: .function])
        #expect(keys.press(.function).consume == false)
        #expect(keys.take() == [.holdPressed])
        keys.advance(2)
        #expect(keys.release(.function).consume == false)
        #expect(keys.take() == [.holdReleased(.keyUp)])
    }

    @Test("Another key within 0.3 s abandons the hold, and that key still reaches the app")
    func chordWithKey() {
        var keys = Keyboard([.holdToTalk: .function])
        keys.press(.function)
        keys.advance(0.29)
        #expect(keys.down(kVK_ANSI_E).consume == false)
        #expect(keys.take() == [.holdPressed, .holdAbandoned])
        keys.up(kVK_ANSI_E)
        keys.release(.function)
        #expect(keys.take() == [], "an abandoned hold has no release")
    }

    @Test("Another modifier within 0.3 s abandons the hold")
    func chordWithModifier() {
        var keys = Keyboard([.holdToTalk: .function])
        keys.press(.function)
        keys.advance(0.1)
        keys.press(.leftShift)
        #expect(keys.take() == [.holdPressed, .holdAbandoned])
        keys.release(.leftShift)
        keys.release(.function)
        #expect(keys.take() == [])
    }

    @Test("A key after 0.3 s leaves the hold running, and its release still ends it")
    func keyAfterWindow() {
        var keys = Keyboard([.holdToTalk: .function])
        keys.press(.function)
        keys.advance(0.31)
        keys.down(kVK_ANSI_A)
        keys.up(kVK_ANSI_A)
        keys.press(.leftShift)
        #expect(keys.take() == [.holdPressed])
        keys.release(.function)
        #expect(keys.take() == [.holdReleased(.keyUp)], "the release matches the press despite Shift")
        keys.release(.leftShift)
        #expect(keys.take() == [])
    }

    @Test("After an abandoned chord the binding does not trigger again until it is pressed afresh")
    func freshPressAfterChord() {
        var keys = Keyboard([.holdToTalk: .function])
        keys.press(.function)
        keys.down(kVK_ANSI_E)
        keys.up(kVK_ANSI_E)
        #expect(keys.take() == [.holdPressed, .holdAbandoned])
        keys.advance(1)
        keys.release(.function)
        keys.press(.function)
        #expect(keys.take() == [.holdPressed])
    }

    @Test("It matches only exactly its keys: Fn pressed with Shift already down starts nothing")
    func exactlyItsKeys() {
        var keys = Keyboard([.holdToTalk: .function])
        keys.press(.leftShift)
        keys.press(.function)
        keys.release(.leftShift)
        #expect(keys.take() == [], "releasing Shift is not a fresh press of Fn")
        keys.release(.function)
        #expect(keys.take() == [])
    }

    @Test("It does not match while another key is held")
    func notWhileAKeyIsHeld() {
        var keys = Keyboard([.holdToTalk: .function])
        keys.down(kVK_ANSI_A)
        keys.press(.function)
        #expect(keys.take() == [])
        keys.release(.function)
        keys.up(kVK_ANSI_A)
        keys.press(.function)
        #expect(keys.take() == [.holdPressed])
    }

    @Test("Sides are tracked per physical key")
    func perPhysicalKey() {
        var keys = Keyboard([.holdToTalk: .modifiers([.rightOption])])
        keys.press(.leftOption)
        keys.release(.leftOption)
        #expect(keys.take() == [], "Left Option is not Right Option")
        keys.press(.rightOption)
        keys.press(.leftOption)
        #expect(keys.take() == [.holdPressed, .holdAbandoned])
    }

    @Test("Releasing the other side of the same modifier does not end the hold")
    func otherSideRelease() {
        var keys = Keyboard([.holdToTalk: .modifiers([.rightCommand])])
        keys.press(.rightCommand)
        keys.advance(1)
        keys.press(.leftCommand)
        keys.release(.leftCommand)
        #expect(keys.take() == [.holdPressed])
        keys.release(.rightCommand)
        #expect(keys.take() == [.holdReleased(.keyUp)])
    }

    @Test("A two-key binding starts when the second key goes down, and ends when either comes up")
    func twoKeys() {
        var keys = Keyboard([.holdToTalk: .modifiers([.leftControl, .leftOption])])
        keys.press(.leftControl)
        #expect(keys.take() == [])
        keys.press(.leftOption)
        #expect(keys.take() == [.holdPressed])
        keys.advance(1)
        keys.release(.leftControl)
        #expect(keys.take() == [.holdReleased(.keyUp)])
        keys.release(.leftOption)
        #expect(keys.take() == [])
    }

    @Test("Escape during a fresh hold cancels rather than abandons")
    func escapeIsNotAChord() {
        var keys = Keyboard([.holdToTalk: .function])
        keys.press(.function)
        keys.advance(0.1)
        #expect(keys.down(kVK_Escape).consume)
        #expect(keys.take() == [.holdPressed, .cancelPressed])
        #expect(keys.up(kVK_Escape).consume)
        keys.release(.function)
        #expect(keys.take() == [.holdReleased(.keyUp)], "the session ignores a release with no hold")
    }
}

@Suite("Key bindings")
struct KeyBindingTests {
    @Test("A key Hold to Talk consumes its down, repeats and up")
    func keyHold() {
        var keys = Keyboard([.holdToTalk: optionSpace])
        keys.press(.leftOption)
        #expect(keys.down(kVK_Space).consume)
        #expect(keys.take() == [.holdPressed])
        #expect(keys.down(kVK_Space, repeat: true).consume)
        #expect(keys.down(kVK_Space, repeat: true).consume)
        #expect(keys.take() == [], "auto-repeat triggers nothing")
        #expect(keys.up(kVK_Space).consume)
        #expect(keys.take() == [.holdReleased(.keyUp)])
    }

    @Test("Releasing the modifier first does not stop the key's release from ending the hold")
    func releaseMatchesPress() {
        var keys = Keyboard([.holdToTalk: optionSpace])
        keys.press(.rightOption)
        keys.down(kVK_Space)
        keys.release(.rightOption)
        #expect(keys.take() == [.holdPressed])
        #expect(keys.up(kVK_Space).consume)
        #expect(keys.take() == [.holdReleased(.keyUp)])
    }

    @Test("Modifiers must match exactly, and the bare key passes through")
    func exactModifiers() {
        var keys = Keyboard([.tapToToggle: optionSpace])
        #expect(keys.down(kVK_Space).consume == false)
        #expect(keys.up(kVK_Space).consume == false)
        keys.press(.leftOption)
        keys.press(.leftShift)
        #expect(keys.down(kVK_Space).consume == false)
        #expect(keys.up(kVK_Space).consume == false)
        #expect(keys.take() == [])
    }

    @Test("Either side of a modifier satisfies a key binding")
    func eitherSide() {
        var keys = Keyboard([.tapToToggle: optionSpace])
        keys.press(.rightOption)
        keys.down(kVK_Space)
        keys.up(kVK_Space)
        #expect(keys.take() == [.togglePressed])
    }

    @Test("Toggle triggers once per fresh key-down")
    func toggleOncePerPress() {
        var keys = Keyboard([.tapToToggle: controlT])
        keys.press(.leftControl)
        keys.down(kVK_ANSI_T)
        keys.down(kVK_ANSI_T, repeat: true)
        keys.up(kVK_ANSI_T)
        keys.down(kVK_ANSI_T)
        keys.up(kVK_ANSI_T)
        #expect(keys.take() == [.togglePressed, .togglePressed])
    }

    @Test("Paste Again is delivered as its own trigger")
    func pasteAgain() {
        var keys = Keyboard([.pasteAgain: commandShiftV])
        keys.press(.leftCommand)
        keys.press(.leftShift)
        #expect(keys.down(kVK_ANSI_V).consume)
        #expect(keys.up(kVK_ANSI_V).consume)
        #expect(keys.take() == [.pasteAgainPressed])
    }

    @Test("A consumed key-down has its key-up consumed even after the bindings change")
    func keyUpAfterBindingsChange() {
        var keys = Keyboard([.tapToToggle: controlT])
        keys.press(.leftControl)
        keys.down(kVK_ANSI_T)
        _ = keys.matcher.setBindings([:])
        #expect(keys.down(kVK_ANSI_T, repeat: true).consume)
        #expect(keys.up(kVK_ANSI_T).consume)
        #expect(keys.down(kVK_ANSI_T).consume == false, "a fresh press is judged by the new bindings")
    }

    @Test("A key held from before passes its repeats and up through")
    func keyHeldFromBefore() {
        var keys = Keyboard([.tapToToggle: controlT])
        keys.press(.leftControl)
        #expect(keys.down(kVK_ANSI_T, repeat: true).consume == false)
        #expect(keys.up(kVK_ANSI_T).consume == false)
        #expect(keys.take() == [], "a repeat is never a press")
    }

    @Test("A modifier-only toggle triggers on press, and a hold can turn into it as a chord")
    func modifierToggleChord() {
        var keys = Keyboard([.holdToTalk: .function, .tapToToggle: .modifiers([.function, .leftShift])])
        keys.press(.function)
        keys.advance(0.1)
        keys.press(.leftShift)
        #expect(keys.take() == [.holdPressed, .holdAbandoned, .togglePressed])
        keys.release(.leftShift)
        keys.release(.function)
        #expect(keys.take() == [])
    }
}

@Suite("Escape")
struct EscapeTests {
    @Test("Escape is consumed only when the handler cancelled something")
    func consumedOnlyWhenHandled() {
        var keys = Keyboard([:])
        keys.handled = false
        #expect(keys.down(kVK_Escape).consume == false)
        #expect(keys.up(kVK_Escape).consume == false)
        keys.handled = true
        #expect(keys.down(kVK_Escape).consume)
        #expect(keys.down(kVK_Escape, repeat: true).consume)
        #expect(keys.up(kVK_Escape).consume)
        #expect(keys.take() == [.cancelPressed, .cancelPressed])
    }

    @Test("Escape repeats never cancel again")
    func repeatsDoNotCancel() {
        var keys = Keyboard([:])
        keys.handled = false
        keys.down(kVK_Escape)
        #expect(keys.down(kVK_Escape, repeat: true).consume == false)
        #expect(keys.take() == [.cancelPressed])
    }

    @Test("Escape with Command, Option or Control belongs to the system or the app; with Shift it cancels")
    func modifiedEscape() {
        var keys = Keyboard([:])
        for key in [ModifierKey.leftCommand, .rightOption, .leftControl] {
            keys.press(key)
            #expect(keys.down(kVK_Escape).consume == false)
            keys.up(kVK_Escape)
            keys.release(key)
        }
        #expect(keys.take() == [])
        keys.press(.leftShift)
        keys.down(kVK_Escape)
        #expect(keys.take() == [.cancelPressed])
    }
}

@Suite("Interruptions")
struct InterruptionTests {
    @Test("Changing the hold's binding ends the hold as interrupted, and its key-up is still consumed")
    func bindingsChange() {
        var keys = Keyboard([.holdToTalk: optionSpace])
        keys.press(.leftOption)
        keys.down(kVK_Space)
        #expect(keys.take() == [.holdPressed])
        #expect(keys.matcher.setBindings([.holdToTalk: .function]) == [.holdReleased(.interrupted)])
        #expect(keys.up(kVK_Space).consume)
        #expect(keys.take() == [], "the release was already delivered as interrupted")
    }

    @Test("Changing another action's binding leaves a hold alone")
    func otherBindingChange() {
        var keys = Keyboard([.holdToTalk: .function])
        keys.press(.function)
        #expect(keys.matcher.setBindings([.holdToTalk: .function, .tapToToggle: controlT]) == [])
        keys.release(.function)
        #expect(keys.take() == [.holdPressed, .holdReleased(.keyUp)])
    }

    @Test("An interruption ends a hold once and forgets stale key state")
    func interruptEndsHold() {
        var keys = Keyboard([.holdToTalk: .function])
        keys.down(kVK_ANSI_A)
        _ = keys.matcher.interrupt()
        keys.press(.function)
        #expect(keys.take() == [.holdPressed], "the key-up lost while interrupted no longer blocks the binding")
        #expect(keys.matcher.interrupt() == [.holdReleased(.interrupted)])
        #expect(keys.matcher.interrupt() == [])
        keys.release(.function)
        #expect(keys.take() == [])
    }

    @Test("A key consumed before an interruption still has its key-up consumed")
    func balancedAcrossInterruption() {
        var keys = Keyboard([.holdToTalk: optionSpace])
        keys.press(.leftOption)
        keys.down(kVK_Space)
        #expect(keys.matcher.interrupt() == [.holdReleased(.interrupted)])
        #expect(keys.up(kVK_Space).consume)
        #expect(keys.take() == [.holdPressed])
    }
}

@Suite("Recording a binding")
struct RecordingTests {
    @Test("A key with modifiers is recorded, and every event of it is consumed")
    func recordsKey() {
        var keys = Keyboard([.holdToTalk: .function])
        #expect(keys.matcher.startRecording() == [])
        #expect(keys.press(.rightOption).consume)
        let response = keys.down(kVK_Space)
        #expect(response == ShortcutMatcher.Response(consume: true, recording: .recorded(optionSpace)))
        #expect(keys.matcher.isRecording == false)
        #expect(keys.up(kVK_Space).consume)
        #expect(keys.release(.rightOption).consume, "a press consumed while recording has its release consumed")
        #expect(keys.take() == [])
    }

    @Test("Modifier keys released together are recorded as a modifier-only binding")
    func recordsModifiers() {
        var keys = Keyboard([:])
        _ = keys.matcher.startRecording()
        keys.press(.leftControl)
        keys.press(.leftOption)
        #expect(keys.release(.leftOption) == ShortcutMatcher.Response(consume: true))
        let response = keys.release(.leftControl)
        #expect(response == ShortcutMatcher.Response(consume: true,
                                                     recording: .recorded(.modifiers([.leftControl, .leftOption]))))
    }

    @Test("Fn alone is recorded as Fn")
    func recordsFunction() {
        var keys = Keyboard([:])
        _ = keys.matcher.startRecording()
        keys.press(.function)
        #expect(keys.release(.function).recording == .recorded(.function))
    }

    @Test("Nothing triggers while recording, Escape included, and Escape cancels the recording")
    func noTriggersWhileRecording() {
        var keys = Keyboard([.holdToTalk: .function, .tapToToggle: controlT])
        _ = keys.matcher.startRecording()
        keys.press(.function)
        #expect(keys.down(kVK_Escape) == ShortcutMatcher.Response(consume: true, recording: .cancelled))
        #expect(keys.up(kVK_Escape).consume)
        #expect(keys.release(.function).consume)
        #expect(keys.take() == [])
        keys.press(.function)
        #expect(keys.take() == [.holdPressed], "matching resumes after the recording")
    }

    @Test("A modifier held from before the recording passes through and does not end it")
    func modifierFromBefore() {
        var keys = Keyboard([:])
        keys.press(.leftCommand)
        _ = keys.matcher.startRecording()
        #expect(keys.release(.leftCommand) == ShortcutMatcher.Response(consume: false))
        #expect(keys.matcher.isRecording)
        keys.press(.rightShift)
        #expect(keys.release(.rightShift).recording == .recorded(.modifiers([.rightShift])))
    }

    @Test("A key repeating from before the recording is not recorded")
    func repeatFromBefore() {
        var keys = Keyboard([:])
        _ = keys.matcher.startRecording()
        #expect(keys.down(kVK_ANSI_A, repeat: true) == ShortcutMatcher.Response(consume: false))
        #expect(keys.matcher.isRecording)
    }

    @Test("Starting to record ends a hold as interrupted")
    func recordingInterruptsHold() {
        var keys = Keyboard([.holdToTalk: .function])
        keys.press(.function)
        #expect(keys.matcher.startRecording() == [.holdReleased(.interrupted)])
        #expect(keys.release(.function).consume == false, "Fn went down before recording: its release passes")
        #expect(keys.take() == [.holdPressed])
    }

    @Test("Cancelling keeps key state balanced")
    func cancelBalanced() {
        var keys = Keyboard([:])
        _ = keys.matcher.startRecording()
        keys.press(.leftOption)
        keys.matcher.cancelRecording()
        #expect(keys.release(.leftOption).consume)
        #expect(keys.matcher.isRecording == false)
    }

    @Test("An interruption cancels the recording")
    func interruptionCancels() {
        var keys = Keyboard([:])
        _ = keys.matcher.startRecording()
        _ = keys.matcher.interrupt()
        #expect(keys.matcher.isRecording == false)
    }
}
