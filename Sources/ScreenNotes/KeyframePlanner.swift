import Foundation

/// Why a moment was chosen as a keyframe.
public enum KeyframeReason: String, Codable, Sendable, Comparable {
    case start, end, gap, speech, click, ink, pin

    /// Which reason's moment stands for moments merged with it: ink and pins, then clicks, then speech, then the rest.
    public var priority: Int {
        switch self {
        case .start, .end, .gap: 0
        case .speech: 1
        case .click: 2
        case .ink, .pin: 3
        }
    }

    public static func < (a: KeyframeReason, b: KeyframeReason) -> Bool {
        let order: [KeyframeReason] = [.start, .ink, .pin, .click, .speech, .gap, .end]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}

/// One moment of the recording shown as an image.
public struct Keyframe: Codable, Equatable, Sendable {
    /// From 1, in time order.
    public var number: Int
    public var time: Double
    /// Every reason that led to it, sorted.
    public var reasons: [KeyframeReason]

    public init(number: Int, time: Double, reasons: [KeyframeReason]) {
        self.number = number
        self.time = time
        self.reasons = reasons
    }

    /// The image's path inside the note's folder.
    public var file: String { "frames/" + Self.fileName(number) }

    public static func fileName(_ number: Int) -> String { String(format: "frame-%02d.png", number) }

    private enum CodingKeys: String, CodingKey { case number, time, file, reasons }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        number = try values.decode(Int.self, forKey: .number)
        time = try values.decode(Double.self, forKey: .time)
        reasons = try values.decode([KeyframeReason].self, forKey: .reasons)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(number, forKey: .number)
        try values.encode(time, forKey: .time)
        try values.encode(file, forKey: .file)
        try values.encode(reasons, forKey: .reasons)
    }
}

/// Chooses a note's keyframes (ARCHITECTURE.md, section 14, "The note", step 2). Pure: the same note always gives the
/// same keyframes.
public enum KeyframePlanner {
    /// The first keyframe's time, past the first frames a stream may deliver blank.
    public static let startTime: Double = 0.3
    /// How far before the end the last keyframe is.
    public static let endMargin: Double = 0.1
    /// After a stroke ends or a pin drops, so the mark is complete on the frame.
    public static let markDelay: Double = 0.1
    /// After a click, so the frame shows what the click did.
    public static let clickDelay: Double = 0.3
    /// About how long a word lasts, for a phrase's end.
    public static let wordLength: Double = 0.5
    /// A word that starts this long after the one before it starts a phrase.
    public static let pause: Double = 1
    /// A phrase is never longer than this, from its first word to its last.
    public static let longestPhrase: Double = 8
    /// Moments closer than this are one.
    public static let mergeWindow: Double = 1.5
    /// A longer stretch with nothing in it gets keyframes of its own.
    public static let longestGap: Double = 10
    public static let maximum = 16

    private struct Moment {
        var time: Double
        var reasons: Set<KeyframeReason>
        /// The reason whose time the moment has.
        var lead: KeyframeReason
    }

    public static func plan(duration: Double, marks: NoteMarks, words: [NoteWord]) -> [Keyframe] {
        let duration = max(duration, 0)
        // Every time is inside the video: a frame exactly at its end does not exist.
        let last = max(duration - endMargin, 0)
        let first = min(startTime, last)
        func clamp(_ t: Double) -> Double { min(max(t, first), last) }

        var moments = [Moment(time: first, reasons: [.start], lead: .start)]
        if last > first { moments.append(Moment(time: last, reasons: [.end], lead: .end)) }
        for stroke in marks.strokes {
            moments.append(Moment(time: clamp(stroke.end + markDelay), reasons: [.ink], lead: .ink))
        }
        for pin in marks.pins {
            moments.append(Moment(time: clamp(pin.time + markDelay), reasons: [.pin], lead: .pin))
        }
        for click in marks.clicks {
            moments.append(Moment(time: clamp(click.time + clickDelay), reasons: [.click], lead: .click))
        }
        for end in phraseEnds(words) {
            moments.append(Moment(time: clamp(end), reasons: [.speech], lead: .speech))
        }
        moments.sort { $0.time < $1.time }

        moments = merged(moments)
        moments = filled(moments)
        moments = capped(moments)
        return moments.enumerated().map { index, moment in
            Keyframe(number: index + 1, time: moment.time, reasons: moment.reasons.sorted())
        }
    }

    /// The narration in phrases, in order: each ends after a word ending in `.`, `?` or `!`, before a word that starts
    /// `pause` or more after the one before it, before a word that would make it longer than `longestPhrase`, and at
    /// the last word.
    public static func phrases(_ words: [NoteWord]) -> [[NoteWord]] {
        var phrases: [[NoteWord]] = [], phrase: [NoteWord] = []
        for word in words {
            if let first = phrase.first, let previous = phrase.last,
               word.time - previous.time >= pause || word.time - first.time > longestPhrase {
                phrases.append(phrase)
                phrase = []
            }
            phrase.append(word)
            if let mark = word.text.last, ".?!".contains(mark) {
                phrases.append(phrase)
                phrase = []
            }
        }
        if !phrase.isEmpty { phrases.append(phrase) }
        return phrases
    }

    /// The phrases keyframe `index` owns: those whose last word is in its span, in order.
    public static func phrases(of index: Int, in keyframes: [Keyframe], words: [NoteWord]) -> [[NoteWord]] {
        let span = span(of: index, in: keyframes)
        return phrases(words).filter { span.contains($0.last!.time) }
    }

    /// Where each phrase ends: after its last word, and never after the next word starts.
    static func phraseEnds(_ words: [NoteWord]) -> [Double] {
        let phrases = phrases(words)
        return phrases.indices.map { index in
            let next = index + 1 < phrases.count ? phrases[index + 1][0].time : .infinity
            return min(phrases[index].last!.time + wordLength, next)
        }
    }

    /// Joins neighbours closer than `mergeWindow`, one pair at a time, the closest first, until none are. The moment
    /// that stands for a pair has the time of its higher-priority lead, the later one on a tie.
    private static func merged(_ input: [Moment]) -> [Moment] {
        var moments = input
        while moments.count > 1 {
            let gaps = (0..<(moments.count - 1)).map { moments[$0 + 1].time - moments[$0].time }
            guard let index = gaps.indices.min(by: { gaps[$0] < gaps[$1] }), gaps[index] < mergeWindow else { break }
            let a = moments[index], b = moments[index + 1]
            let winner = a.lead.priority > b.lead.priority ? a : b
            moments[index] = Moment(time: winner.time, reasons: a.reasons.union(b.reasons), lead: winner.lead)
            moments.remove(at: index + 1)
        }
        return moments
    }

    /// Spaces keyframes evenly through each stretch longer than `longestGap`.
    private static func filled(_ moments: [Moment]) -> [Moment] {
        guard var previous = moments.first else { return moments }
        var result = [previous]
        for moment in moments.dropFirst() {
            let gap = moment.time - previous.time
            if gap > longestGap {
                let pieces = Int((gap / longestGap).rounded(.up))
                for piece in 1..<pieces {
                    let time = previous.time + gap * Double(piece) / Double(pieces)
                    result.append(Moment(time: time, reasons: [.gap], lead: .gap))
                }
            }
            result.append(moment)
            previous = moment
        }
        return result
    }

    /// Drops keyframes over `maximum`: never the first or the last; the lowest priority first, and among equals the
    /// one closest to a neighbour.
    private static func capped(_ input: [Moment]) -> [Moment] {
        var moments = input
        while moments.count > maximum {
            let inner = 1..<(moments.count - 1)
            func priority(_ i: Int) -> Int { moments[i].reasons.map(\.priority).max() ?? 0 }
            func crowding(_ i: Int) -> Double {
                min(moments[i].time - moments[i - 1].time, moments[i + 1].time - moments[i].time)
            }
            let lowest = inner.map(priority).min() ?? 0
            let candidates = inner.filter { priority($0) == lowest }
            guard let drop = candidates.min(by: { crowding($0) < crowding($1) }) else { break }
            moments.remove(at: drop)
        }
        return moments
    }

    /// The span keyframe `index` owns: from halfway to the one before to halfway to the one after, the first from the
    /// very start and the last to the very end, so every moment belongs to exactly one keyframe.
    public static func span(of index: Int, in keyframes: [Keyframe]) -> Range<Double> {
        let lower = index == 0 ? -Double.infinity : (keyframes[index - 1].time + keyframes[index].time) / 2
        let upper = index == keyframes.count - 1 ? Double.infinity
            : (keyframes[index].time + keyframes[index + 1].time) / 2
        return lower..<upper
    }
}
