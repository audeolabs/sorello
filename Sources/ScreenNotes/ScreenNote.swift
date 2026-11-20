import CoreGraphics
import Foundation

/// Everything a finished note holds once its keyframes are chosen: what the summary, the manifest and the frames are
/// made from (ARCHITECTURE.md, section 14, "The note").
public struct ScreenNote: Equatable, Sendable {
    public var startedAt: Date
    /// Seconds.
    public var duration: Double
    /// The recorded display, in points.
    public var display: CGSize
    /// The keyframes' size, in pixels.
    public var frameSize: CGSize
    public var marks: NoteMarks
    /// With the dictionary's casing.
    public var words: [NoteWord]
    public var narration: Narration
    public var keyframes: [Keyframe]

    /// A note whose keyframes `KeyframePlanner` chooses.
    public init(startedAt: Date, duration: Double, display: CGSize, frameSize: CGSize, marks: NoteMarks,
                words: [NoteWord], narration: Narration) {
        self.startedAt = startedAt
        self.duration = duration
        self.display = display
        self.frameSize = frameSize
        self.marks = marks
        self.words = words
        self.narration = narration
        keyframes = KeyframePlanner.plan(duration: duration, marks: marks, words: words)
    }

    /// What one keyframe owns: the marks, clicks and phrases in its span.
    public struct Content: Equatable, Sendable {
        public var keyframe: Keyframe
        /// The phrases of the narration that end in its span, in order.
        public var phrases: [[NoteWord]]
        public var words: [NoteWord] { phrases.flatMap { $0 } }
        /// What was said in its span, as one line.
        public var said: String { words.map(\.text).joined(separator: " ") }
        /// Strokes that end in its span.
        public var strokes: [Stroke]
        public var pins: [Pin]
        public var clicks: [Click]
    }

    /// A phrase of the narration stays whole: its words go with the keyframe whose span holds its last word.
    public func content(of index: Int) -> Content {
        let span = KeyframePlanner.span(of: index, in: keyframes)
        return Content(keyframe: keyframes[index],
                       phrases: KeyframePlanner.phrases(words).filter { span.contains($0.last!.time) },
                       strokes: marks.strokes.filter { span.contains($0.end) },
                       pins: marks.pins.filter { span.contains($0.time) },
                       clicks: marks.clicks.filter { span.contains($0.time) })
    }

    /// What is drawn on keyframe `index`: the strokes and pins of its span, and every stroke still in progress at its
    /// time, cut at that time.
    public func drawing(of index: Int) -> (strokes: [Stroke], pins: [Pin]) {
        let own = content(of: index)
        let time = keyframes[index].time
        var strokes = own.strokes
        for stroke in marks.strokes where stroke.start <= time && stroke.end > time {
            guard !strokes.contains(where: { $0.number == stroke.number }) else { continue }
            let points = stroke.points.filter { $0.t <= time }
            if points.count >= 2 { strokes.append(Stroke(number: stroke.number, points: points)) }
        }
        return (strokes.sorted { $0.number < $1.number }, own.pins)
    }

    /// A place as whole pixels of a keyframe.
    public func pixels(x: Double, y: Double) -> (x: Int, y: Int) {
        (Int((x * Double(frameSize.width)).rounded()), Int((y * Double(frameSize.height)).rounded()))
    }

    /// `m:ss`, or `h:mm:ss` from an hour.
    public static func clock(_ seconds: Double) -> String {
        let whole = max(Int(seconds.rounded(.down)), 0)
        let h = whole / 3600, m = (whole / 60) % 60, s = whole % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
