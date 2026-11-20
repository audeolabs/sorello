import Foundation
import ScreenNotes
import Testing

/// ARCHITECTURE.md, section 14, "The note", step 2.
@Suite struct KeyframePlannerTests {
    /// Times as the planner computes them, which sums of decimals reach only to within rounding.
    static func same(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 }
    }

    static func stroke(_ number: Int, from start: Double, to end: Double) -> Stroke {
        Stroke(number: number, points: [TimedPoint(t: start, x: 0.1, y: 0.1), TimedPoint(t: end, x: 0.2, y: 0.1)])
    }

    @Test func aNoteWithNothingInItHasItsFirstAndLastMoments() {
        let frames = KeyframePlanner.plan(duration: 5, marks: NoteMarks(), words: [])
        #expect(Self.same(frames.map(\.time), [0.3, 4.9]))
        #expect(frames.map(\.reasons) == [[.start], [.end]])
        #expect(frames.map(\.number) == [1, 2])
        #expect(frames.map(\.file) == ["frames/frame-01.png", "frames/frame-02.png"])
    }

    @Test func aVeryShortNoteHasOneKeyframe() {
        let frames = KeyframePlanner.plan(duration: 0.2, marks: NoteMarks(), words: [])
        #expect(frames.count == 1)
        #expect(Self.same([frames[0].time], [0.1]), "inside the video, which has no frame at its very end")
    }

    @Test func eachMarkClickAndPhraseGetsAMomentJustAfterIt() {
        let marks = NoteMarks(strokes: [Self.stroke(1, from: 3, to: 4)],
                              pins: [Pin(number: 1, time: 8, x: 0.5, y: 0.5)],
                              clicks: [Click(time: 12, x: 0.5, y: 0.5)])
        let words = [NoteWord(time: 15, text: "This"), NoteWord(time: 15.3, text: "breaks."),
                     NoteWord(time: 15.6, text: "Then")]
        let frames = KeyframePlanner.plan(duration: 20, marks: marks, words: words)
        // "Then" is a phrase of its own, the last; its end, 16.1, stands for both, the later on a tie.
        #expect(Self.same(frames.map(\.time), [0.3, 4.1, 8.1, 12.3, 16.1, 19.9]))
        #expect(frames.map(\.reasons) == [[.start], [.ink], [.pin], [.click], [.speech], [.end]])
    }

    @Test func aPhraseEndsHalfASecondAfterItsLastWordUnlessTheNextStartsSooner() {
        let words = [NoteWord(time: 5, text: "Look."), NoteWord(time: 9, text: "Here?")]
        let frames = KeyframePlanner.plan(duration: 20, marks: NoteMarks(), words: words)
        #expect(frames.contains { abs($0.time - 5.5) < 1e-9 })
        #expect(frames.contains { abs($0.time - 9.5) < 1e-9 })
    }

    @Test func momentsCloserThanTheWindowAreOneTakingTheHigherPrioritysTime() {
        let marks = NoteMarks(strokes: [Self.stroke(1, from: 5, to: 6)], clicks: [Click(time: 5.2, x: 0, y: 0)])
        let words = [NoteWord(time: 6.5, text: "there.")]
        let frames = KeyframePlanner.plan(duration: 12, marks: marks, words: words)
        let middle = frames.filter { !$0.reasons.contains(.start) && !$0.reasons.contains(.end) }
        #expect(middle.count == 1)
        #expect(Self.same([middle[0].time], [6.1]))
        #expect(middle[0].reasons == [.ink, .click, .speech])
    }

    @Test func noTwoKeyframesAreCloserThanTheWindow() {
        let clicks = stride(from: 1.0, to: 30, by: 0.4).map { Click(time: $0, x: 0, y: 0) }
        let frames = KeyframePlanner.plan(duration: 30, marks: NoteMarks(clicks: clicks), words: [])
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(b.time - a.time >= KeyframePlanner.mergeWindow) }
    }

    @Test func aLongQuietStretchGetsEvenlySpacedKeyframes() {
        let frames = KeyframePlanner.plan(duration: 25.4, marks: NoteMarks(), words: [])
        #expect(frames.map(\.reasons) == [[.start], [.gap], [.gap], [.end]])
        #expect(Self.same(frames.map(\.time), [0.3, 0.3 + 25.0 / 3, 0.3 + 50.0 / 3, 25.3]))
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(b.time - a.time <= KeyframePlanner.longestGap) }
    }

    @Test func thereAreNeverMoreThanSixteenAndTheFirstAndLastStay() {
        var strokes: [Stroke] = []
        for index in 0..<20 { strokes.append(Self.stroke(index + 1, from: Double(index) * 2, to: Double(index) * 2 + 1)) }
        let clicks = (0..<20).map { Click(time: 60 + Double($0) * 2, x: 0, y: 0) }
        let frames = KeyframePlanner.plan(duration: 120, marks: NoteMarks(strokes: strokes, clicks: clicks), words: [])
        #expect(frames.count == KeyframePlanner.maximum)
        #expect(frames.first?.reasons.contains(.start) == true)
        #expect(frames.last?.reasons.contains(.end) == true)
        // Ink outranks clicks and gaps, so the keyframes kept are the strokes' (the first merged with the start).
        #expect(frames.filter { $0.reasons.contains(.ink) }.count == 15)
        #expect(!frames.contains { $0.reasons.contains(.click) || $0.reasons.contains(.gap) })
    }

    @Test func spansCoverTheWholeNoteOnceSplitHalfwayBetweenKeyframes() {
        let frames = KeyframePlanner.plan(duration: 20, marks: NoteMarks(), words: [])
        #expect(frames.count == 3)
        let spans = frames.indices.map { KeyframePlanner.span(of: $0, in: frames) }
        #expect(spans[0].upperBound == spans[1].lowerBound)
        #expect(spans[1].upperBound == spans[2].lowerBound)
        #expect(spans[0].contains(-1) && spans[2].contains(1000))
        #expect(spans[1].lowerBound == (frames[0].time + frames[1].time) / 2)
    }
}
