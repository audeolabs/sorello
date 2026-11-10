import ApplicationServices
import CoreGraphics

/// One keyboard event as the tap read it, before normalization.
struct RawKeyEvent: Sendable, Equatable {
    var type: CGEventType
    var keyCode: UInt16
    var flags: CGEventFlags
    var isRepeat: Bool
    /// The event's source user data: `SyntheticEvents.tag` marks Sorello's own events.
    var sourceUserData: Int64
}

/// What the tap tells its owner.
enum TapMessage: Sendable, Equatable {
    case key(RawKeyEvent)
    /// The system disabled the tap (it took too long, or user input disabled it). Events were missed.
    case disabled
}

/// The keyboard event tap behind `ShortcutMonitor`, so the monitor can be tested without a real tap. Everything
/// happens on the main thread.
@MainActor
protocol KeyEventTapping: AnyObject {
    /// Creates and enables the tap, or returns false if it cannot: without Accessibility it is never attempted,
    /// so no permission prompt can appear. `receive` returns whether to swallow the event.
    func install(_ receive: @escaping @MainActor (TapMessage) -> Bool) -> Bool
    /// Enables the tap again after the system disabled it.
    func reenable()
    /// Removes the tap. No message arrives after this returns.
    func remove()
}

/// An active event tap at the session level on the main run loop, reading key down, key up and flags changed.
@MainActor
final class SessionEventTap: KeyEventTapping {
    private final class Receiver {
        let receive: @MainActor (TapMessage) -> Bool
        init(_ receive: @escaping @MainActor (TapMessage) -> Bool) { self.receive = receive }
    }

    private let isTrusted: @MainActor () -> Bool
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    /// Held here; the tap's callback borrows it through its user-info pointer while the tap exists.
    private var receiver: Receiver?

    /// `isTrusted` is asked before the tap is created. The default never prompts.
    init(isTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() }) {
        self.isTrusted = isTrusted
    }

    func install(_ receive: @escaping @MainActor (TapMessage) -> Bool) -> Bool {
        if port != nil { return true }
        guard isTrusted() else { return false }
        let receiver = Receiver(receive)
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: sessionEventTapCallback, userInfo: Unmanaged.passUnretained(receiver).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.receiver = receiver
        self.port = port
        self.source = source
        return true
    }

    func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    func remove() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
        receiver = nil
    }

    /// Called by the callback, on the main thread, with the address of the receiver it was given.
    fileprivate static func deliver(_ message: TapMessage, toReceiverAt address: UInt) -> Bool {
        guard let pointer = UnsafeRawPointer(bitPattern: address) else { return false }
        return Unmanaged<Receiver>.fromOpaque(pointer).takeUnretainedValue().receive(message)
    }
}

extension TapMessage {
    /// Reads what the shortcuts need from an event the tap was given; nil for an event type they ignore.
    init?(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            self = .disabled
        case .keyDown, .keyUp, .flagsChanged:
            self = .key(RawKeyEvent(
                type: type, keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                flags: event.flags, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                sourceUserData: event.getIntegerValueField(.eventSourceUserData)))
        default:
            return nil
        }
    }
}

/// The tap's C callback. The tap's run loop source is on the main run loop, so this runs on the main thread; it
/// enters the main actor with a checked assumption, normalizes, decides and returns without waiting.
private func sessionEventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                     userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo, let message = TapMessage(type: type, event: event) else {
        return Unmanaged.passUnretained(event)
    }
    let address = UInt(bitPattern: userInfo)
    let consume = MainActor.assumeIsolated {
        SessionEventTap.deliver(message, toReceiverAt: address)
    }
    return consume ? nil : Unmanaged.passUnretained(event)
}
