import Foundation

/// The opening (ARCHITECTURE.md, "Keyboard look", "The opening"): when a dictation starts, Start's ring mark opens into
/// the recording's row of dots. The ring's eight dots are beads on one string with the state dot at its head, and as
/// the progress goes from 0 to 1 (over `duration`, eased in and out) the string goes from the ring, dot for dot as Start
/// draws it, to the wave's row, dot for dot as `DotWave` draws it: the state dot becomes the dot the wave settles into,
/// and the white dots the seven of the row nearest it. The string is a row, a run-out and a dip. The row lies along a
/// level that lifts from the ring's bottom to the row's own line. At first the ring turns in place, so its dots run out
/// of its bottom and away along the row; the state dot comes over its top and down to the row's end, and what is left
/// of the ring hangs beside it as a dip that widens, grows shallow and is pulled flat. The run-out joins the dip's
/// bottom to the row without a kink. The row's other dots join on behind the seventh, a pitch apart, and brighten over
/// the second half. Every point is in one coordinate space, y downward; right-handed the row runs leftwards from the
/// state dot, and mirrored everything is the exact mirror image (the row runs rightwards). Pure.
enum RingOpening {
    /// How long the opening takes, in seconds, from the change of form.
    static let duration = 0.65
    /// How much wider than the ring the dip grows as it empties: its radius goes to `1 + widening` times the ring's.
    static let widening = 1.6
    /// How far the ring settles below where it was, as a fraction of its radius, while the row lifts.
    static let settling = 0.2
    /// The eased progress by which the row has lifted to its line.
    static let lifted = 0.35
    /// The eased progress by which the state dot is over the top of the ring: the time may arrive from then on, not
    /// before, as until then the ring stands where the time will be.
    static let timeArrives = 0.45

    /// How long after the opening begins the time may arrive, in seconds (`timeArrives`).
    static var timeDelay: Double { progress(eased: timeArrives) * duration }

    /// One of the opening's two resting ends.
    enum End: Equatable, Sendable {
        case ring, row
    }

    /// The string at one moment: the state dot, and every other dot, the white dots first (nearest the state dot
    /// first), then the row's other dots in order away from it. A dot's `brightness` is its strength: the ink's opacity.
    struct Frame: Equatable, Sendable {
        var stateDot: DotWave.Dot
        var dots: [DotWave.Dot]
        /// The level the string's row lies along at this moment.
        var rowLevel: Double
        /// The dip at this moment: the circle what is left of the ring hangs on, the state dot on it.
        var dip: Dip
    }

    /// A circle: its centre and radius.
    struct Dip: Equatable, Sendable {
        var x: Double
        var y: Double
        var radius: Double
    }

    /// Whether a row of `rowCount` dots can take the ring's seven white dots. In a narrower island there is no opening.
    static func applies(rowCount: Int) -> Bool {
        rowCount >= RingMark.whiteCount
    }

    /// The progress eased in and out: slow from the ring, quick through the middle, slow into the row.
    static func eased(_ progress: Double) -> Double {
        let t = min(max(progress, 0), 1)
        return t < 0.5 ? 2 * t * t : 1 - (2 - 2 * t) * (2 - 2 * t) / 2
    }

    /// The progress at which the eased progress is `eased` (clamped to 0...1; not a number is 0): `eased`'s inverse.
    static func progress(eased: Double) -> Double {
        let e = eased.isNaN ? 0 : min(max(eased, 0), 1)
        return e <= 0.5 ? (e / 2).squareRoot() : 1 - (2 * (1 - e)).squareRoot() / 2
    }

    /// The ring mark as Start draws it in `box` (`RingMark.fitted`), mirrored across the box's middle when `mirrored`.
    static func ring(in box: KeyRect, mirrored: Bool) -> RingMark.Fitted {
        var mark = RingMark.fitted(in: box)
        guard mirrored else { return mark }
        func reflect(_ point: RingMark.Point) -> RingMark.Point { RingMark.Point(x: 2 * box.midX - point.x, y: point.y) }
        mark.stateDot = reflect(mark.stateDot)
        mark.whiteDots = mark.whiteDots.map(reflect)
        return mark
    }

    /// The string at `progress` (0 is the ring, 1 the row; outside that it clamps, and a progress that is not a number
    /// is the end `resting`), from the ring Start draws in `ring` to the row `row` with its mark's dot `mark`, as the
    /// wave draws them. `mirrored`: the ring is mirrored (`ring(in:mirrored:)`) and the row runs rightwards from the
    /// mark's dot. `stateStrength` is the state dot's as Start shows it at the first moment (below 1 while it breathes;
    /// clamped to 0...1, not a number is 1); it goes to the mark's dot's with the eased progress. A row that cannot
    /// take the ring's dots (`applies`) has no opening: the ring until the end, then the row.
    static func frame(ring box: KeyRect, row: [DotWave.Dot], mark: DotWave.Dot, progress: Double, mirrored: Bool = false,
                      stateStrength: Double = 1, resting: End = .ring) -> Frame {
        let progress = progress.isNaN ? (resting == .ring ? 0 : 1) : min(max(progress, 0), 1)
        let stateStrength = stateStrength.isNaN ? 1 : min(max(stateStrength, 0), 1)
        // Nearest the mark's dot first.
        let row = row.sorted { abs($0.x - mark.x) < abs($1.x - mark.x) }
        let ringMark = ring(in: box, mirrored: mirrored)
        let ringFrame = Frame(
            stateDot: DotWave.Dot(x: ringMark.stateDot.x, y: ringMark.stateDot.y, radius: ringMark.stateRadius,
                                  brightness: stateStrength),
            dots: ringMark.whiteDots.map {
                DotWave.Dot(x: $0.x, y: $0.y, radius: ringMark.whiteRadius, brightness: RingMark.whiteStrength)
            },
            rowLevel: box.midY + RingMark.ringRadius * max(0, min(box.width, box.height)) / RingMark.side,
            dip: Dip(x: box.midX, y: box.midY, radius: RingMark.ringRadius * max(0, min(box.width, box.height)) / RingMark.side))
        if progress >= 1 {
            // Pulled flat: the dip's widest circle, its bottom at the state dot.
            let radius = ringFrame.dip.radius * (1 + widening)
            return Frame(stateDot: mark, dots: row, rowLevel: mark.y, dip: Dip(x: mark.x, y: mark.y - radius, radius: radius))
        }
        guard applies(rowCount: row.count) else { return ringFrame }
        // Worked right-handed: mirrored, x is negated on the way in and on the way out.
        let flip: Double = mirrored ? -1 : 1
        let flippedBox = mirrored ? KeyRect(x: -box.maxX, y: box.y, width: box.width, height: box.height) : box
        func flipped(_ dot: DotWave.Dot) -> DotWave.Dot {
            DotWave.Dot(x: flip * dot.x, y: dot.y, radius: dot.radius, brightness: dot.brightness)
        }
        var frame = rightHanded(ring: flippedBox, row: row.map(flipped), mark: flipped(mark), progress: progress,
                                stateStrength: stateStrength)
        frame.stateDot = flipped(frame.stateDot)
        frame.dots = frame.dots.map(flipped)
        frame.dip.x *= flip
        guard progress <= 0 else { return frame }
        // At its first moment the string is the ring exactly; the dots that join later are there, unseen.
        frame.stateDot = ringFrame.stateDot
        frame.dots.replaceSubrange(0 ..< ringFrame.dots.count, with: ringFrame.dots)
        frame.rowLevel = ringFrame.rowLevel
        frame.dip = ringFrame.dip
        return frame
    }

    /// Smoothstep, clamped to 0...1.
    private static func smooth(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// From `a` at 0 to `b` at 1, each end exact.
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a * (1 - t) + b * t }

    /// The string with the row running leftwards from `mark`; `row` is nearest the mark first and has at least seven dots.
    private static func rightHanded(ring box: KeyRect, row: [DotWave.Dot], mark: DotWave.Dot, progress: Double,
                                    stateStrength: Double) -> Frame {
        let e = eased(progress)
        let scale = max(0, min(box.width, box.height)) / RingMark.side
        let ringRadius = RingMark.ringRadius * scale
        let centre = (x: box.midX, y: box.midY)
        let stateAngle = RingMark.stateAngle * .pi / 180
        // How far round from the dip's bottom the state dot still is, and the dip's radius: it widens as it empties.
        let turn = stateAngle * (1 - e)
        let rho = ringRadius * (1 + widening * smooth((e - 0.6) / 0.4))
        // 0 until the state dot is over the top, 1 once it is level with the row.
        let down = smooth((.pi - turn) / (.pi / 2))
        // The state dot's height above the dip's bottom, and the dip's bottom: at first the ring's bottom, settling a
        // little as the row lifts; at last where the state dot sits on the row's line.
        let rise = rho * (1 - cos(turn))
        let bottomY = lerp(centre.y + ringRadius * (1 + settling * smooth(e / 0.45)), mark.y + rise, down)
        let bottomX = lerp(centre.x, mark.x - rho * sin(turn), down)
        let rowLevel = lerp(centre.y + ringRadius, mark.y, smooth(e / lifted))
        let runOut = RunOut(radius: rho, drop: max(0, bottomY - rowLevel))
        let dipLength = rho * turn, dipCentreY = bottomY - rho

        /// The point `s` points along the string from the state dot.
        func at(_ s: Double) -> (x: Double, y: Double) {
            if s <= dipLength {
                let angle = turn - s / rho
                return (bottomX + rho * sin(angle), dipCentreY + rho * cos(angle))
            }
            let u = s - dipLength
            if u < runOut.length {
                let point = runOut.point(at: u)
                return (bottomX - point.x, bottomY - point.y)
            }
            let end = runOut.points[runOut.points.count - 1]
            return (bottomX - end.x - (u - runOut.length), rowLevel)
        }

        // How far behind the state dot each dot is along the string: as on the ring at first, as in the row at last. The
        // white dots keep the ring's spacing while the ring first turns (spreading at once would push the last of them
        // round the ring's open bottom into the state dot), and take the row's by the end.
        let spread = e * e
        let ringStep = RingMark.whiteSpacing * .pi / 180 * ringRadius
        let rowGaps = row.map { mark.x - $0.x }
        let whiteCount = RingMark.whiteCount
        let lastWhite = lerp(Double(whiteCount) * ringStep, rowGaps[whiteCount - 1], spread)
        let joining = max(0, (e - 0.45) / 0.55)
        var dots: [DotWave.Dot] = []
        dots.reserveCapacity(row.count)
        for (index, target) in row.enumerated() {
            if index < whiteCount {
                let point = at(lerp(Double(index + 1) * ringStep, rowGaps[index], spread))
                dots.append(DotWave.Dot(x: point.x, y: point.y,
                                        radius: lerp(RingMark.whiteRadius * scale, target.radius, e),
                                        brightness: lerp(RingMark.whiteStrength, target.brightness, e)))
            } else {
                // A dot the row has and the ring has not joins on behind the ring's last, so the row never gaps.
                let point = at(lastWhite + rowGaps[index] - rowGaps[whiteCount - 1])
                dots.append(DotWave.Dot(x: point.x, y: point.y, radius: target.radius, brightness: target.brightness * joining))
            }
        }
        let head = at(0)
        let state = DotWave.Dot(x: head.x, y: head.y, radius: lerp(RingMark.stateRadius * scale, mark.radius, e),
                                brightness: lerp(stateStrength, mark.brightness, e))
        return Frame(stateDot: state, dots: dots, rowLevel: rowLevel, dip: Dip(x: bottomX, y: dipCentreY, radius: rho))
    }

    /// The run-out: the stretch of string between the dip's bottom and the row, `drop` above it. It leaves the bottom
    /// bending as the dip (of `radius`) bends; its bend eases through straight into a gentle opposite bend and out to
    /// nothing where it meets the row, so there is no kink anywhere along the string: its slope at the fraction `v` of
    /// its length `L` is `(L / radius) v (1 - v)²` radians. Its length is whatever that shape needs to climb `drop`.
    /// Points are measured leftwards and upwards from the dip's bottom.
    private struct RunOut {
        static let steps = 40
        let length: Double
        let points: [(x: Double, y: Double)]

        init(radius: Double, drop: Double) {
            func shape(_ length: Double) -> [(x: Double, y: Double)] {
                var x = 0.0, y = 0.0
                var points = [(x: 0.0, y: 0.0)]
                points.reserveCapacity(Self.steps + 1)
                let step = length / Double(Self.steps)
                for i in 0 ..< Self.steps {
                    let v = (Double(i) + 0.5) / Double(Self.steps)
                    let slope = length / radius * v * (1 - v) * (1 - v)
                    x += cos(slope) * step
                    y += sin(slope) * step
                    points.append((x, y))
                }
                return points
            }
            // The climb grows with the length (its steepest slope stays under a right angle up to eight radii).
            var low = 0.0, high = 8 * radius
            for _ in 0 ..< 40 {
                let middle = (low + high) / 2
                if shape(middle)[Self.steps].y < drop { low = middle } else { high = middle }
            }
            length = high
            points = shape(high)
        }

        /// The point `u` points along it.
        func point(at u: Double) -> (x: Double, y: Double) {
            let position = u / length * Double(Self.steps)
            let index = min(Self.steps - 1, Int(position)), w = position - Double(index)
            let a = points[index], b = points[index + 1]
            return (a.x + (b.x - a.x) * w, a.y + (b.y - a.y) * w)
        }
    }
}
