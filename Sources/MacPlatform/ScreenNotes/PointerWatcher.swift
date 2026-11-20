import AppKit
import Foundation

/// What the pointer did while a note records, in points of the recorded display from its top left, at seconds from
/// the note's start.
public enum PointerEvent: Sendable, Equatable {
    case moved(CGPoint, time: Double, shift: Bool)
    case buttonDown(CGPoint, time: Double, shift: Bool)
    case buttonUp(CGPoint, time: Double)
}

/// Reads the pointer, ⇧ and the left button while a note records (ARCHITECTURE.md, section 14, "Marks"), taking no
/// input from anyone: the place and ⇧ are read 60 times a second, and the button through event monitors, which see
/// clicks without catching them. None of it needs a permission.
@MainActor
public final class PointerWatcher {
    public static let interval: TimeInterval = 1.0 / 60

    private var timer: Timer?
    private var monitors: [Any] = []
    private var last: (point: CGPoint, shift: Bool)?

    public init() {}

    /// Whether these modifiers draw: ⇧ alone. ⇧ with ⌘, ⌥ or ⌃ is a shortcut being pressed, as ⌥⇧S is to finish.
    nonisolated public static func drawsInk(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.shift, .command, .option, .control]) == .shift
    }

    /// Starts reading for `display`. `startedAt` is the note's zero, as `ProcessInfo.systemUptime`.
    public func start(display: NoteDisplay, startedAt: TimeInterval, handler: @escaping @MainActor (PointerEvent) -> Void) {
        stop()
        let frame = display.frame
        func local(_ location: NSPoint) -> CGPoint { CGPoint(x: location.x - frame.minX, y: frame.maxY - location.y) }
        func now() -> Double { ProcessInfo.processInfo.systemUptime - startedAt }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                let point = local(NSEvent.mouseLocation), shift = Self.drawsInk(NSEvent.modifierFlags)
                if let last = self.last, last.point == point, last.shift == shift { return }
                self.last = (point, shift)
                handler(.moved(point, time: now(), shift: shift))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // A click is placed and timed by its own event, which may be delivered after the pointer has moved on: a global
        // monitor's event has its place on the screen, and its timestamp is seconds since startup, the note's clock.
        // Only other apps' clicks are heard (Sorello's own windows, the pill among them, are not in the recording),
        // and a press off the recorded display is not part of the note.
        let button: @MainActor (NSEvent) -> Void = { event in
            let point = local(event.locationInWindow), time = event.timestamp - startedAt
            if event.type == .leftMouseDown {
                guard frame.contains(event.locationInWindow) else { return }
                handler(.buttonDown(point, time: time, shift: Self.drawsInk(event.modifierFlags)))
            } else {
                handler(.buttonUp(point, time: time))
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { event in
            MainActor.assumeIsolated { button(event) }
        }) { monitors.append(global) }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        last = nil
    }
}
