import CoreGraphics
import Foundation

extension ScreenNote {
    /// The note's file names inside its folder.
    public enum Files {
        public static let recording = "recording.mov"
        public static let summary = "summary.md"
        public static let manifest = "note.json"
        public static let contactSheet = "contact-sheet.png"
        public static let frames = "frames"
    }

    /// `summary.md`: what the folder is and where it is, then each keyframe with what was said and done in its span,
    /// places in pixels of that keyframe (ARCHITECTURE.md, section 14, "The note", step 5). `folder` is the note's
    /// folder; `date` is the start as the reader's clock shows it.
    public func summary(folder: String, date: String) -> String {
        var lines: [String] = [
            "# Screen note",
            "",
            "A screen recording with narration, made with Sorello to show a problem. Each section below is one "
                + "keyframe: an image in this folder, what was said around it and what was clicked or drawn on it. "
                + "\(Files.contactSheet) shows every keyframe at once.",
            "",
            "- Folder: \(folder)",
            "- Recorded: \(date)",
            "- Length: \(Self.clock(duration))",
            "- Keyframes: \(keyframes.count), \(Int(frameSize.width))×\(Int(frameSize.height)) px",
            "- Marks: \(Self.count(marks.strokes.count, "stroke")), \(Self.count(marks.pins.count, "pin")), "
                + "\(Self.count(marks.clicks.count, "click"))",
            "- Narration: \(narrationLine)",
        ]
        for index in keyframes.indices {
            let own = content(of: index)
            let keyframe = own.keyframe
            lines += ["", "## \(keyframe.number) · \(Self.clock(keyframe.time)) · \(keyframe.file)", ""]
            let said = own.said
            for (index, phrase) in own.phrases.enumerated() {
                if index > 0 { lines.append(">") }
                lines.append("> \(Self.clock(phrase[0].time)) \(phrase.map(\.text).joined(separator: " "))")
            }
            var events: [(time: Double, text: String)] = []
            for click in own.clicks {
                let p = pixels(x: click.x, y: click.y)
                events.append((click.time, "click at (\(p.x), \(p.y))"))
            }
            for stroke in own.strokes {
                let xs = stroke.points.map(\.x), ys = stroke.points.map(\.y)
                let low = pixels(x: xs.min() ?? 0, y: ys.min() ?? 0), high = pixels(x: xs.max() ?? 0, y: ys.max() ?? 0)
                events.append((stroke.end, "stroke \(stroke.number) drawn over (\(low.x), \(low.y))–(\(high.x), \(high.y))"))
            }
            for pin in own.pins {
                let p = pixels(x: pin.x, y: pin.y)
                events.append((pin.time, "pin \(pin.number) at (\(p.x), \(p.y))"))
            }
            if !said.isEmpty && !events.isEmpty { lines.append("") }
            for event in events.sorted(by: { $0.time < $1.time }) {
                lines.append("- \(Self.clock(event.time)) \(event.text)")
            }
            if said.isEmpty && events.isEmpty { lines.append("Nothing said or done.") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private var narrationLine: String {
        switch narration {
        case .transcribed: words.isEmpty ? "nothing was said" : "transcribed on this Mac"
        case .noMicrophone: "none, because Sorello may not use the microphone"
        case .notTranscribed(let reason): "recorded but not transcribed: \(reason)"
        }
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// `note.json` (ARCHITECTURE.md, section 14, "The note", step 6).
    public func manifest() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(NoteManifest(self))
    }
}

/// The manifest's shape. `version` changes only when a field changes meaning or goes away.
public struct NoteManifest: Codable, Equatable, Sendable {
    public struct Size: Codable, Equatable, Sendable {
        public var width: Double
        public var height: Double
    }

    public var version: Int
    /// ISO 8601, in UTC.
    public var startedAt: String
    public var duration: Double
    public var display: Size
    public var frame: Size
    public var keyframes: [Keyframe]
    public var words: [NoteWord]
    public var strokes: [Stroke]
    public var pins: [Pin]
    public var clicks: [Click]
    /// `transcribed`, `noMicrophone` or `notTranscribed`.
    public var narration: String
    public var narrationProblem: String?

    public static let currentVersion = 1

    public init(_ note: ScreenNote) {
        version = Self.currentVersion
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        startedAt = formatter.string(from: note.startedAt)
        duration = note.duration
        display = Size(width: Double(note.display.width), height: Double(note.display.height))
        frame = Size(width: Double(note.frameSize.width), height: Double(note.frameSize.height))
        keyframes = note.keyframes
        words = note.words
        strokes = note.marks.strokes
        pins = note.marks.pins
        clicks = note.marks.clicks
        switch note.narration {
        case .transcribed: narration = "transcribed"
        case .noMicrophone: narration = "noMicrophone"
        case .notTranscribed(let reason):
            narration = "notTranscribed"
            narrationProblem = reason
        }
    }
}

/// Where each keyframe goes on the contact sheet: a grid, in order, at most `columns` across, each `cellWidth` wide
/// with its label under it and its caption, what was said, under that; a row is as tall as its tallest caption
/// (ARCHITECTURE.md, section 14, "The note", step 4). Pixels, from the sheet's top left.
public struct ContactSheetLayout: Equatable, Sendable {
    public static let columns = 4
    public static let cellWidth: Double = 640
    public static let gap: Double = 16
    public static let labelHeight: Double = 32

    public var size: CGSize
    /// Each keyframe's image.
    public var images: [CGRect]
    /// Each keyframe's label, under its image.
    public var labels: [CGRect]
    /// Each keyframe's caption, under its label, as tall as it was measured.
    public var captions: [CGRect]

    /// `captionHeights` are the captions' measured heights, one per keyframe; missing ones are 0.
    public init(count: Int, frameSize: CGSize, captionHeights: [Double] = []) {
        let columns = max(min(count, Self.columns), 1)
        let rows = max((count + columns - 1) / columns, 1)
        let aspect = frameSize.width > 0 ? Double(frameSize.height / frameSize.width) : 9.0 / 16
        let imageHeight = (Self.cellWidth * aspect).rounded()
        func caption(_ index: Int) -> Double { index < captionHeights.count ? max(captionHeights[index], 0) : 0 }
        images = []
        labels = []
        captions = []
        var y = Self.gap
        for row in 0..<rows {
            let members = (row * columns)..<min((row + 1) * columns, max(count, 1))
            let tallest = members.map(caption).max() ?? 0
            for index in members where index < count {
                let x = Self.gap + Double(index % columns) * (Self.cellWidth + Self.gap)
                images.append(CGRect(x: x, y: y, width: Self.cellWidth, height: imageHeight))
                labels.append(CGRect(x: x, y: y + imageHeight, width: Self.cellWidth, height: Self.labelHeight))
                captions.append(CGRect(x: x, y: y + imageHeight + Self.labelHeight, width: Self.cellWidth,
                                       height: caption(index)))
            }
            y += imageHeight + Self.labelHeight + tallest + Self.gap
        }
        size = CGSize(width: Self.gap + Double(columns) * (Self.cellWidth + Self.gap), height: y)
    }
}
