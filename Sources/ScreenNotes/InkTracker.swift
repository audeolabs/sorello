import CoreGraphics
import Foundation

/// Turns the pointer, ⇧ and the left button into a note's marks (ARCHITECTURE.md, section 14, "Marks"). A pure state
/// machine: the adapter feeds it what it reads, in time order, with places in points of the recorded display from its
/// top left, and it keeps strokes, pins and clicks as fractions of that display.
///
/// - While ⇧ is held, moving the pointer draws. Releasing ⇧ ends the stroke; one under `minimumInk` long is not ink.
/// - A click while ⇧ is held, before that hold has drawn ink, drops a pin where the button went down, if the press
///   moved less than `pinSlop` and lasted less than `pinDuration`. A click later in the same hold is drawing.
/// - Any other left click is a click.
/// - On a touch screen a finger draws without ⇧: a drag is a stroke, a short small tap a pin. One finger at a time.
/// - `undo` removes the last stroke or pin.
public struct InkTracker: Sendable {
    /// Shorter than this, in points, a ⇧ hold's path is not ink.
    public static let minimumInk: Double = 12
    /// A ⇧-click that moves this far, in points, is not a pin.
    public static let pinSlop: Double = 12
    /// A ⇧-click held this long, in seconds, is not a pin.
    public static let pinDuration: Double = 1

    /// The display's size in points.
    public let display: CGSize

    public private(set) var strokes: [Stroke] = []
    public private(set) var pins: [Pin] = []
    public private(set) var clicks: [Click] = []

    /// The ⇧ hold in progress.
    private struct Hold {
        /// The path since the hold began, or since the pin it dropped.
        var path: [TimedPoint]
        /// Its length in points.
        var length: Double = 0
        /// Whether it has drawn ink: once it has, a click is part of the drawing.
        var isInk: Bool { length >= InkTracker.minimumInk }
    }

    private struct Press {
        var time: Double
        var at: CGPoint
        /// Whether it may be a pin: made during a ⇧ hold that had drawn no ink.
        var mayPin: Bool
        var farthest: Double = 0
    }

    /// A finger on the screen.
    private struct Touch {
        var path: [TimedPoint]
        var length: Double = 0
        /// Where and when it touched.
        var at: CGPoint
        var time: Double
        var last: CGPoint
        var farthest: Double = 0
        var isInk: Bool { length >= InkTracker.minimumInk }
    }

    private enum Mark { case stroke, pin }

    private var touch: Touch?
    private var hold: Hold?
    private var press: Press?
    private var last: CGPoint?
    /// The marks in the order they were made, for undo.
    private var made: [Mark] = []

    public init(display: CGSize) {
        self.display = display
    }

    /// The stroke being drawn now, once it is long enough to be ink.
    public var current: [TimedPoint]? {
        if let touch, touch.isInk { return touch.path }
        guard let hold, hold.isInk else { return nil }
        return hold.path
    }

    /// A finger touched the screen at `point`. Ignored while another finger is drawing.
    public mutating func touchBegan(at point: CGPoint, time: Double) {
        guard touch == nil else { return }
        touch = Touch(path: [fraction(point, time)], at: point, time: time, last: point)
    }

    /// The finger drawing moved to `point`.
    public mutating func touchMoved(at point: CGPoint, time: Double) {
        guard var touch else { return }
        touch.farthest = max(touch.farthest, distance(touch.at, point))
        if point != touch.last {
            touch.length += distance(touch.last, point)
            touch.path.append(fraction(point, time))
            touch.last = point
        }
        self.touch = touch
    }

    /// The finger drawing lifted at `point`: a stroke if it drew ink, a pin if it was a tap, otherwise nothing.
    public mutating func touchEnded(at point: CGPoint, time: Double) {
        touchMoved(at: point, time: time)
        guard let ended = touch else { return }
        touch = nil
        if ended.isInk {
            endTouch(ended, at: time)
        } else if ended.farthest < Self.pinSlop, time - ended.time < Self.pinDuration {
            let place = fraction(ended.at, ended.time)
            pins.append(Pin(number: pins.count + 1, time: ended.time, x: place.x, y: place.y))
            made.append(.pin)
        }
    }

    /// The pointer is at `point` at `time`, with ⇧ down or not.
    public mutating func pointer(at point: CGPoint, time: Double, shift: Bool) {
        defer { last = point }
        if var press {
            press.farthest = max(press.farthest, distance(press.at, point))
            self.press = press
        }
        guard shift else {
            endHold(at: time)
            return
        }
        let here = fraction(point, time)
        guard var hold else {
            hold = Hold(path: [here])
            return
        }
        if let previous = last, previous != point {
            hold.length += distance(previous, point)
            hold.path.append(here)
        }
        self.hold = hold
    }

    /// The left button went down at `point`.
    public mutating func buttonDown(at point: CGPoint, time: Double, shift: Bool) {
        // The pointer may have moved since the last sample; the press is where it is now, and no ink leads to it.
        defer { last = point }
        if shift {
            if hold == nil { hold = Hold(path: [fraction(point, time)]) }
            press = Press(time: time, at: point, mayPin: !(hold?.isInk ?? false))
        } else {
            press = Press(time: time, at: point, mayPin: false)
            let place = fraction(point, time)
            clicks.append(Click(time: time, x: place.x, y: place.y))
        }
    }

    /// The left button came up at `point`.
    public mutating func buttonUp(at point: CGPoint, time: Double) {
        defer { last = point }
        guard var press else { return }
        self.press = nil
        press.farthest = max(press.farthest, distance(press.at, point))
        guard press.mayPin, hold.map({ !$0.isInk }) ?? true else { return }
        guard press.farthest < Self.pinSlop, time - press.time < Self.pinDuration else {
            // Too long or too far for a pin, and no ink: an ordinary click, where and when the button went down.
            let place = fraction(press.at, press.time)
            clicks.append(Click(time: press.time, x: place.x, y: place.y))
            return
        }
        let place = fraction(press.at, press.time)
        pins.append(Pin(number: pins.count + 1, time: press.time, x: place.x, y: place.y))
        made.append(.pin)
        // The movement before the pin is not the start of a stroke.
        hold = Hold(path: [fraction(point, time)])
    }

    /// Removes the last stroke or pin. Returns whether there was one.
    @discardableResult
    public mutating func undo() -> Bool {
        // A finger still drawing is the newest mark; the rest of its path is not drawn.
        if let touch, touch.isInk {
            self.touch = nil
            return true
        }
        // A stroke still held (⇧ released, but not sampled yet) is the newest mark.
        if let hold, hold.isInk {
            self.hold = nil
            return true
        }
        guard let mark = made.popLast() else { return false }
        switch mark {
        case .stroke: strokes.removeLast()
        case .pin: pins.removeLast()
        }
        return true
    }

    /// Ends what is in progress, as the note finishes, and returns the marks. A stroke still drawn ends at its last
    /// point.
    public mutating func finish() -> NoteMarks {
        if let touch, touch.isInk { endTouch(touch, at: nil) }
        touch = nil
        endHold(at: nil)
        press = nil
        return NoteMarks(strokes: strokes, pins: pins, clicks: clicks)
    }

    /// Ends the ⇧ hold. A stroke ends when ⇧ is released, `time`, where the pointer last was.
    private mutating func endHold(at time: Double?) {
        guard var ended = hold else { return }
        hold = nil
        guard ended.isInk else { return }
        if let time, let lastPoint = ended.path.last, time > lastPoint.t {
            ended.path.append(TimedPoint(t: time, x: lastPoint.x, y: lastPoint.y))
        }
        strokes.append(Stroke(number: strokes.count + 1, points: ended.path))
        made.append(.stroke)
    }

    /// Keeps a finger's stroke, ending at `time` where it last was.
    private mutating func endTouch(_ ended: Touch, at time: Double?) {
        var path = ended.path
        if let time, let lastPoint = path.last, time > lastPoint.t {
            path.append(TimedPoint(t: time, x: lastPoint.x, y: lastPoint.y))
        }
        strokes.append(Stroke(number: strokes.count + 1, points: path))
        made.append(.stroke)
    }

    private func fraction(_ point: CGPoint, _ time: Double) -> TimedPoint {
        let width = max(Double(display.width), 1), height = max(Double(display.height), 1)
        return TimedPoint(t: time, x: min(max(Double(point.x) / width, 0), 1),
                          y: min(max(Double(point.y) / height, 0), 1))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(a.x - b.x, a.y - b.y))
    }
}
