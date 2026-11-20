import CoreGraphics
import Foundation

// What a screen note records besides its video (ARCHITECTURE.md, section 14, "Marks"). Places are fractions of the
// recorded display from its top left, so they land in the same place on a keyframe of any size; times are seconds
// from the start of the recording.

/// A place on the display at a moment.
public struct TimedPoint: Equatable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double

    public init(t: Double, x: Double, y: Double) {
        self.t = t
        self.x = x
        self.y = y
    }
}

extension TimedPoint: Codable {
    /// Written as `[t, x, y]`, since a stroke has many.
    public init(from decoder: any Decoder) throws {
        var values = try decoder.unkeyedContainer()
        t = try values.decode(Double.self)
        x = try values.decode(Double.self)
        y = try values.decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(t)
        try values.encode(x)
        try values.encode(y)
    }
}

/// One stroke of ink: the pointer's path while ⇧ was held.
public struct Stroke: Codable, Equatable, Sendable {
    /// From 1, in the order strokes were made.
    public var number: Int
    /// At least two, in time order.
    public var points: [TimedPoint]

    public init(number: Int, points: [TimedPoint]) {
        self.number = number
        self.points = points
    }

    public var start: Double { points.first?.t ?? 0 }
    public var end: Double { points.last?.t ?? 0 }

    private enum CodingKeys: String, CodingKey { case number, start, end, points }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        number = try values.decode(Int.self, forKey: .number)
        points = try values.decode([TimedPoint].self, forKey: .points)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(number, forKey: .number)
        try values.encode(start, forKey: .start)
        try values.encode(end, forKey: .end)
        try values.encode(points, forKey: .points)
    }
}

/// A numbered pin, dropped by a ⇧-click.
public struct Pin: Codable, Equatable, Sendable {
    public var number: Int
    public var time: Double
    public var x: Double
    public var y: Double

    public init(number: Int, time: Double, x: Double, y: Double) {
        self.number = number
        self.time = time
        self.x = x
        self.y = y
    }
}

/// A left click with no ⇧, which the app underneath received.
public struct Click: Codable, Equatable, Sendable {
    public var time: Double
    public var x: Double
    public var y: Double

    public init(time: Double, x: Double, y: Double) {
        self.time = time
        self.x = x
        self.y = y
    }
}

/// One word of the narration and when it was said.
public struct NoteWord: Codable, Equatable, Sendable {
    public var time: Double
    public var text: String

    public init(time: Double, text: String) {
        self.time = time
        self.text = text
    }
}

/// What became of the narration.
public enum Narration: Equatable, Sendable {
    /// Transcribed by the speech engine. The words may be none: nothing was said.
    case transcribed
    /// Not recorded: microphone access was not granted.
    case noMicrophone
    /// Recorded but not transcribed, for this reason, said in plain words.
    case notTranscribed(String)
}

/// The marks of one note, as `InkTracker` gives them when the note finishes.
public struct NoteMarks: Equatable, Sendable {
    public var strokes: [Stroke]
    public var pins: [Pin]
    public var clicks: [Click]

    public init(strokes: [Stroke] = [], pins: [Pin] = [], clicks: [Click] = []) {
        self.strokes = strokes
        self.pins = pins
        self.clicks = clicks
    }
}
