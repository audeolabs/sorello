import CoreGraphics
import Foundation
import ScreenNotes
import Testing

/// ARCHITECTURE.md, section 14, "Marks": ink while ⇧ is held, pins from a ⇧-click, plain clicks, and undo.
@Suite struct InkTrackerTests {
    static let display = CGSize(width: 1000, height: 500)

    /// Moves the pointer along `points` with ⇧ held, one sample every 10 ms from `from`.
    static func draw(_ tracker: inout InkTracker, _ points: [CGPoint], from: Double) {
        for (index, point) in points.enumerated() {
            tracker.pointer(at: point, time: from + Double(index) * 0.01, shift: true)
        }
    }

    @Test func movingWithShiftDrawsAStrokeThatEndsWhenShiftIsReleased() {
        var tracker = InkTracker(display: Self.display)
        tracker.pointer(at: CGPoint(x: 100, y: 100), time: 0.9, shift: false)
        Self.draw(&tracker, [CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 100), CGPoint(x: 200, y: 100)], from: 1)
        #expect(tracker.current?.count == 3)
        #expect(tracker.strokes.isEmpty)
        tracker.pointer(at: CGPoint(x: 200, y: 100), time: 1.5, shift: false)
        #expect(tracker.current == nil)
        let stroke = try! #require(tracker.strokes.first)
        #expect(stroke.number == 1)
        #expect(stroke.points.first == TimedPoint(t: 1, x: 0.1, y: 0.2))
        #expect(stroke.points.last == TimedPoint(t: 1.5, x: 0.2, y: 0.2), "it ends where the pointer was, at the release")
        #expect(stroke.start == 1 && stroke.end == 1.5)
    }

    @Test func aPathUnderTwelvePointsIsNotInk() {
        var tracker = InkTracker(display: Self.display)
        Self.draw(&tracker, [CGPoint(x: 100, y: 100), CGPoint(x: 105, y: 100), CGPoint(x: 111, y: 100)], from: 1)
        #expect(tracker.current == nil)
        tracker.pointer(at: CGPoint(x: 111, y: 100), time: 2, shift: false)
        #expect(tracker.strokes.isEmpty)
    }

    @Test func movingWithoutShiftDrawsNothing() {
        var tracker = InkTracker(display: Self.display)
        for x in stride(from: 0.0, through: 300, by: 30) {
            tracker.pointer(at: CGPoint(x: x, y: 10), time: x / 100, shift: false)
        }
        let marks = tracker.finish()
        #expect(marks == NoteMarks())
    }

    @Test func aShiftClickBeforeAnyInkDropsAPinWhereTheButtonWentDown() {
        var tracker = InkTracker(display: Self.display)
        tracker.pointer(at: CGPoint(x: 500, y: 250), time: 1, shift: true)
        tracker.buttonDown(at: CGPoint(x: 500, y: 250), time: 1.1, shift: true)
        tracker.pointer(at: CGPoint(x: 505, y: 252), time: 1.2, shift: true)
        tracker.buttonUp(at: CGPoint(x: 505, y: 252), time: 1.3)
        #expect(tracker.pins == [Pin(number: 1, time: 1.1, x: 0.5, y: 0.5)])
        #expect(tracker.clicks.isEmpty)
        tracker.pointer(at: CGPoint(x: 505, y: 252), time: 1.4, shift: false)
        #expect(tracker.strokes.isEmpty)
    }

    @Test func aShiftClickWhereThePointerWentBetweenSamplesIsStillAPin() {
        var tracker = InkTracker(display: Self.display)
        tracker.pointer(at: CGPoint(x: 100, y: 100), time: 1, shift: false)
        // The pointer moved to (400, 300) and ⇧ went down before the next sample; the press comes first.
        tracker.buttonDown(at: CGPoint(x: 400, y: 300), time: 1.01, shift: true)
        tracker.pointer(at: CGPoint(x: 400, y: 300), time: 1.02, shift: true)
        tracker.buttonUp(at: CGPoint(x: 400, y: 300), time: 1.1)
        tracker.pointer(at: CGPoint(x: 400, y: 300), time: 1.2, shift: false)
        #expect(tracker.pins == [Pin(number: 1, time: 1.01, x: 0.4, y: 0.6)])
        #expect(tracker.strokes.isEmpty)
    }

    @Test func aShiftPressThatMovesOrLastsTooLongIsNoPin() {
        var moved = InkTracker(display: Self.display)
        moved.buttonDown(at: CGPoint(x: 100, y: 100), time: 1, shift: true)
        moved.pointer(at: CGPoint(x: 100, y: 113), time: 1.1, shift: true)
        moved.buttonUp(at: CGPoint(x: 100, y: 100), time: 1.2)
        #expect(moved.pins.isEmpty)

        var long = InkTracker(display: Self.display)
        long.buttonDown(at: CGPoint(x: 100, y: 100), time: 1, shift: true)
        long.buttonUp(at: CGPoint(x: 100, y: 100), time: 2)
        #expect(long.pins.isEmpty)
        #expect(long.clicks == [Click(time: 1, x: 0.1, y: 0.2)], "a press that is not a pin, and drew nothing, is a click")
    }

    @Test func aClickAfterInkInTheSameHoldIsPartOfTheDrawing() {
        var tracker = InkTracker(display: Self.display)
        Self.draw(&tracker, [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)], from: 1)
        tracker.buttonDown(at: CGPoint(x: 200, y: 100), time: 1.1, shift: true)
        tracker.buttonUp(at: CGPoint(x: 200, y: 100), time: 1.2)
        tracker.pointer(at: CGPoint(x: 200, y: 100), time: 1.3, shift: false)
        #expect(tracker.pins.isEmpty)
        #expect(tracker.clicks.isEmpty)
        #expect(tracker.strokes.count == 1)
    }

    @Test func aPlainClickIsRecordedWithItsPlaceAndTime() {
        var tracker = InkTracker(display: Self.display)
        tracker.buttonDown(at: CGPoint(x: 250, y: 125), time: 3, shift: false)
        tracker.buttonUp(at: CGPoint(x: 250, y: 125), time: 3.1)
        #expect(tracker.clicks == [Click(time: 3, x: 0.25, y: 0.25)])
        #expect(tracker.pins.isEmpty)
    }

    @Test func undoRemovesTheLastStrokeOrPinAndNumbersCarryOn() {
        var tracker = InkTracker(display: Self.display)
        Self.draw(&tracker, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], from: 1)
        tracker.pointer(at: CGPoint(x: 100, y: 0), time: 1.5, shift: false)
        tracker.buttonDown(at: CGPoint(x: 300, y: 300), time: 2, shift: true)
        tracker.buttonUp(at: CGPoint(x: 300, y: 300), time: 2.1)
        tracker.pointer(at: CGPoint(x: 300, y: 300), time: 2.2, shift: false)
        let first = tracker.undo()
        #expect(first)
        #expect(tracker.pins.isEmpty)
        #expect(tracker.strokes.count == 1)
        let second = tracker.undo()
        #expect(second)
        #expect(tracker.strokes.isEmpty)
        let third = tracker.undo()
        #expect(!third)
        Self.draw(&tracker, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], from: 3)
        let marks = tracker.finish()
        #expect(marks.strokes.map(\.number) == [1])
    }

    @Test func undoTakesBackAStrokeStillHeld() {
        var tracker = InkTracker(display: Self.display)
        Self.draw(&tracker, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], from: 1)
        // ⌘Z before the sample that sees ⇧ released.
        let undone = tracker.undo()
        #expect(undone)
        tracker.pointer(at: CGPoint(x: 100, y: 0), time: 2, shift: false)
        #expect(tracker.strokes.isEmpty)
    }

    @Test func finishingEndsAStrokeInProgress() {
        var tracker = InkTracker(display: Self.display)
        Self.draw(&tracker, [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0)], from: 1)
        let marks = tracker.finish()
        #expect(marks.strokes.count == 1)
    }

    @Test func placesOffTheDisplayAreKeptOnIt() {
        var tracker = InkTracker(display: Self.display)
        tracker.buttonDown(at: CGPoint(x: -20, y: 900), time: 1, shift: false)
        #expect(tracker.clicks == [Click(time: 1, x: 0, y: 1)])
    }
}
