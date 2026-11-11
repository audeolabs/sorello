import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import DictationCore
@testable import MacPlatform
import Testing

@MainActor
private final class FakeTap: KeyEventTapping {
    var canInstall = true
    private(set) var receive: (@MainActor (TapMessage) -> Bool)?
    private(set) var installs = 0
    private(set) var reenables = 0
    private(set) var removals = 0

    func install(_ receive: @escaping @MainActor (TapMessage) -> Bool) -> Bool {
        installs += 1
        guard canInstall else { return false }
        self.receive = receive
        return true
    }

    func reenable() { reenables += 1 }

    func remove() {
        removals += 1
        receive = nil
    }

    /// Sends a message as the tap would and returns whether the monitor swallowed it.
    @discardableResult
    func send(_ message: TapMessage) -> Bool { receive?(message) ?? false }
}

@MainActor
private final class FakeInterruptions: SystemInterruptionObserving {
    private var interrupted: (@MainActor () -> Void)?
    private(set) var starts = 0

    func start(_ interrupted: @escaping @MainActor () -> Void) {
        starts += 1
        self.interrupted = interrupted
    }

    func stop() { interrupted = nil }

    /// The screen locked, the user switched away, or the Mac is going to sleep.
    func fire() { interrupted?() }
}

@MainActor
private final class Handler: TriggerHandling {
    var received: [TriggerEvent] = []
    var times: [TimeInterval] = []
    var answer = true

    func handle(_ trigger: TriggerEvent, at time: TimeInterval) -> Bool {
        received.append(trigger)
        times.append(time)
        return answer
    }

    func take() -> [TriggerEvent] {
        defer { received = [] }
        return received
    }
}

@MainActor
private struct Rig {
    let tap = FakeTap()
    let interruptions = FakeInterruptions()
    let handler = Handler()
    let clock = TestClock()
    var secure = SecureFlag()
    let monitor: ShortcutMonitor

    final class SecureFlag {
        var on = false
    }

    init(bindings: [ShortcutAction: ShortcutBinding] = [.holdToTalk: .function], canInstall: Bool = true,
         secure: Bool = false) {
        let flag = SecureFlag()
        flag.on = secure
        self.secure = flag
        tap.canInstall = canInstall
        monitor = ShortcutMonitor(bindings: bindings, clock: clock, tap: tap, interruptions: interruptions,
                                  isSecureInputEnabled: { flag.on })
        monitor.handler = handler
    }

    static func raw(_ type: CGEventType, _ code: Int, _ flags: CGEventFlags = [], repeat isRepeat: Bool = false,
                    tag: Int64 = 0) -> TapMessage {
        .key(RawKeyEvent(type: type, keyCode: UInt16(code), flags: flags, isRepeat: isRepeat, sourceUserData: tag))
    }

    static let fnDown = raw(.flagsChanged, kVK_Function, .maskSecondaryFn)
    static let fnUp = raw(.flagsChanged, kVK_Function)
    static let escapeDown = raw(.keyDown, kVK_Escape)
    static let escapeUp = raw(.keyUp, kVK_Escape)
}

@MainActor
@Suite("Shortcut monitor")
struct ShortcutMonitorTests {
    @Test("With a tap it runs, and Fn becomes a hold stamped with the clock's time")
    func runsAndDelivers() {
        let rig = Rig()
        rig.monitor.start()
        #expect(rig.monitor.status == .running)
        #expect(rig.tap.send(Rig.fnDown) == false)
        rig.clock.advance(by: 1.5)
        rig.tap.send(Rig.fnUp)
        #expect(rig.handler.received == [.holdPressed, .holdReleased(.keyUp)])
        #expect(rig.handler.times == [1_000, 1_001.5])
    }

    @Test("Without a tap it needs Accessibility, and starting again retries")
    func needsAccessibility() {
        let rig = Rig(canInstall: false)
        rig.monitor.start()
        #expect(rig.monitor.status == .needsAccessibility)
        rig.tap.canInstall = true
        rig.monitor.start()
        #expect(rig.monitor.status == .running)
        #expect(rig.tap.installs == 2)
        #expect(rig.interruptions.starts == 1, "observers are installed once, independent of the tap")
    }

    @Test("Escape is swallowed only when the handler cancelled something")
    func escape() {
        let rig = Rig()
        rig.monitor.start()
        rig.handler.answer = false
        #expect(rig.tap.send(Rig.escapeDown) == false)
        #expect(rig.tap.send(Rig.escapeUp) == false)
        rig.handler.answer = true
        #expect(rig.tap.send(Rig.escapeDown))
        #expect(rig.tap.send(Rig.escapeUp))
        #expect(rig.handler.received == [.cancelPressed, .cancelPressed])
    }

    @Test("Sorello's own events pass through untouched")
    func syntheticEvents() {
        let rig = Rig(bindings: [.tapToToggle: .key(code: UInt16(kVK_ANSI_V), modifiers: .command)])
        rig.monitor.start()
        let commandV = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
        #expect(rig.tap.send(Rig.raw(.keyDown, kVK_ANSI_V, commandV, tag: SyntheticEvents.tag)) == false)
        #expect(rig.tap.send(Rig.raw(.keyDown, kVK_Escape, tag: SyntheticEvents.tag)) == false)
        #expect(rig.handler.received == [])
        #expect(rig.tap.send(Rig.raw(.flagsChanged, kVK_Command, commandV)) == false)
        #expect(rig.tap.send(Rig.raw(.keyDown, kVK_ANSI_V, commandV)))
        #expect(rig.handler.received == [.togglePressed])
    }

    @Test("When the system disables the tap, it is enabled again and a hold ends as interrupted")
    func tapDisabled() {
        let rig = Rig()
        rig.monitor.start()
        rig.tap.send(Rig.fnDown)
        rig.tap.send(.disabled)
        #expect(rig.tap.reenables == 1)
        #expect(rig.handler.take() == [.holdPressed, .holdReleased(.interrupted)])
        rig.tap.send(Rig.fnUp)
        #expect(rig.handler.take() == [])
        #expect(rig.monitor.status == .running)
    }

    @Test("Secure input pauses shortcuts and ends a hold as interrupted; turning it off resumes them")
    func secureInput() {
        let rig = Rig()
        rig.monitor.start()
        rig.tap.send(Rig.fnDown)
        rig.secure.on = true
        rig.monitor.checkSecureInput()
        #expect(rig.monitor.status == .pausedBySecureInput)
        #expect(rig.handler.take() == [.holdPressed, .holdReleased(.interrupted)])
        rig.monitor.checkSecureInput()
        #expect(rig.handler.take() == [], "the hold ends once")
        rig.secure.on = false
        rig.monitor.checkSecureInput()
        #expect(rig.monitor.status == .running)
    }

    @Test("Secure input is checked by the monitor itself while a hold is in progress")
    func secureInputPolledDuringHold() async {
        let rig = Rig()
        rig.monitor.start()
        rig.tap.send(Rig.fnDown)
        rig.secure.on = true
        await rig.clock.waitForSleepers()
        rig.clock.advance(by: ShortcutMonitor.holdPollInterval)
        for _ in 0..<1_000 where rig.monitor.status != .pausedBySecureInput {
            await Task.yield()
        }
        #expect(rig.monitor.status == .pausedBySecureInput)
        #expect(rig.handler.received == [.holdPressed, .holdReleased(.interrupted)])
        rig.monitor.stop()
    }

    @Test("Starting while secure input is on reports paused")
    func startsPaused() {
        let rig = Rig(secure: true)
        rig.monitor.start()
        #expect(rig.monitor.status == .pausedBySecureInput)
        rig.monitor.stop()
    }

    @Test("Changing the hold's binding ends the hold as interrupted")
    func bindingsChange() {
        let rig = Rig()
        rig.monitor.start()
        rig.tap.send(Rig.fnDown)
        rig.monitor.setBindings([.holdToTalk: .modifiers([.rightOption])])
        #expect(rig.monitor.bindings == [.holdToTalk: .modifiers([.rightOption])])
        #expect(rig.handler.take() == [.holdPressed, .holdReleased(.interrupted)])
    }

    @Test("A lock, a user switch or sleep is delivered as systemInterrupted while running")
    func systemInterruptedWhileRunning() {
        let rig = Rig()
        rig.monitor.start()
        rig.interruptions.fire()
        #expect(rig.handler.received == [.systemInterrupted])
    }

    @Test("systemInterrupted is delivered even when the tap could not be created")
    func systemInterruptedWithoutTap() {
        let rig = Rig(canInstall: false)
        rig.monitor.start()
        rig.interruptions.fire()
        #expect(rig.handler.received == [.systemInterrupted])
    }

    @Test("systemInterrupted is delivered while shortcuts are paused by secure input")
    func systemInterruptedWhilePaused() {
        let rig = Rig(secure: true)
        rig.monitor.start()
        #expect(rig.monitor.status == .pausedBySecureInput)
        rig.interruptions.fire()
        #expect(rig.handler.received == [.systemInterrupted])
        rig.monitor.stop()
    }

    @Test("systemInterrupted is delivered while a binding is being recorded, and the recording goes on")
    func systemInterruptedWhileRecording() async {
        let rig = Rig()
        rig.monitor.start()
        let recording = Task { await rig.monitor.recordBinding() }
        await waitUntil { rig.monitor.isRecording }
        rig.interruptions.fire()
        #expect(rig.handler.received == [.systemInterrupted])
        rig.tap.send(Rig.fnDown)
        rig.tap.send(Rig.fnUp)
        #expect(await recording.value == .function)
        #expect(rig.handler.received == [.systemInterrupted], "the recorded keys trigger nothing")
    }

    @Test("Recording captures a key with its modifiers and swallows its events")
    func recordsKey() async {
        let rig = Rig()
        rig.monitor.start()
        let recording = Task { await rig.monitor.recordBinding() }
        await waitUntil { rig.monitor.isRecording }
        let option = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
        #expect(rig.tap.send(Rig.raw(.flagsChanged, kVK_Option, option)))
        #expect(rig.tap.send(Rig.raw(.keyDown, kVK_Space, option)))
        #expect(await recording.value == .key(code: UInt16(kVK_Space), modifiers: .option))
        #expect(rig.monitor.isRecording == false)
        #expect(rig.tap.send(Rig.raw(.keyUp, kVK_Space, option)))
        #expect(rig.tap.send(Rig.raw(.flagsChanged, kVK_Option)))
        #expect(rig.handler.received == [])
    }

    @Test("Escape, cancelling, a new recording or a disabled tap end a recording with nothing")
    func recordingEndsWithNothing() async {
        let rig = Rig()
        rig.monitor.start()

        var recording = Task { await rig.monitor.recordBinding() }
        await waitUntil { rig.monitor.isRecording }
        rig.tap.send(Rig.escapeDown)
        #expect(await recording.value == nil)
        #expect(rig.handler.received == [], "Escape while recording is not a cancel trigger")

        recording = Task { await rig.monitor.recordBinding() }
        await waitUntil { rig.monitor.isRecording }
        rig.monitor.cancelRecording()
        #expect(await recording.value == nil)

        recording = Task { await rig.monitor.recordBinding() }
        await waitUntil { rig.monitor.isRecording }
        let second = Task { await rig.monitor.recordBinding() }
        #expect(await recording.value == nil)
        await waitUntil { rig.monitor.isRecording }
        rig.tap.send(.disabled)
        #expect(await second.value == nil)

        recording = Task { await rig.monitor.recordBinding() }
        await waitUntil { rig.monitor.isRecording }
        recording.cancel()
        #expect(await recording.value == nil)
        await waitUntil { !rig.monitor.isRecording }
        #expect(rig.monitor.isRecording == false)
    }

    @Test("A cancelled recording that was replaced before its cancellation ran leaves the new one alone")
    func lateCancellation() async {
        let rig = Rig()
        rig.monitor.start()
        let first = Task { await rig.monitor.recordBinding() }
        await waitUntil { rig.monitor.isRecording }
        // Queued before the first is cancelled, so it replaces the first before the cancellation reaches the
        // main actor.
        let second = Task { await rig.monitor.recordBinding() }
        first.cancel()
        #expect(await first.value == nil)
        for _ in 0..<100 { await Task.yield() }
        #expect(rig.monitor.isRecording, "the second recording is still open")
        rig.tap.send(Rig.fnDown)
        rig.tap.send(Rig.fnUp)
        #expect(await second.value == .function)
    }

    @Test("Recording without a running tap returns nothing at once")
    func recordingWithoutTap() async {
        let rig = Rig(canInstall: false)
        rig.monitor.start()
        #expect(await rig.monitor.recordBinding() == nil)
    }

    @Test("Stopping removes the tap and the observers, and ends a hold as interrupted")
    func stop() {
        let rig = Rig()
        rig.monitor.start()
        rig.tap.send(Rig.fnDown)
        rig.monitor.stop()
        #expect(rig.monitor.status == .stopped)
        #expect(rig.tap.removals == 1)
        #expect(rig.handler.take() == [.holdPressed, .holdReleased(.interrupted)])
        rig.interruptions.fire()
        #expect(rig.handler.take() == [])
    }

    @Test("The monitor holds its handler weakly")
    func weakHandler() {
        let rig = Rig()
        var handler: Handler? = Handler()
        rig.monitor.handler = handler
        handler = nil
        #expect(rig.monitor.handler == nil)
    }

    @Test("An untrusted process gets needsAccessibility from the real tap, without a prompt",
          .enabled(if: !AXIsProcessTrusted(), "this process is trusted; a real tap must not be opened in tests"))
    func realTapUntrusted() {
        let monitor = ShortcutMonitor(bindings: [.holdToTalk: .function])
        monitor.start()
        #expect(monitor.status == .needsAccessibility)
        monitor.stop()
        #expect(monitor.status == .stopped)
    }
}

/// Yields until `condition` holds, for state another task sets.
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<10_000 where !condition() {
        await Task.yield()
    }
}
