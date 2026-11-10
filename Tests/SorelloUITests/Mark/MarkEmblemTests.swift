import AppKit
import DesignCore
import SwiftUI
import Testing
@testable import SorelloUI

/// The mark at rest in the island's capsule (ARCHITECTURE.md, section 8, "The mark"): the row's ink is centred in the
/// capsule both ways, and the aurora dot's glow is drawn around that dot. Each test reads the rendered picture, as a
/// person sees it, at the two sizes the app shows the emblem and at one and two pixels a point.
@MainActor
struct MarkEmblemTests {
    @Test(arguments: [CGFloat(1), 1.4], [CGFloat(1), 2])
    func theRowSitsOnTheCapsulesMiddle(scale: CGFloat, pixels: CGFloat) throws {
        let emblem = try EmblemPicture(scale: scale, pixels: pixels)
        let middle = try emblem.capsuleMiddle()
        let white = try emblem.whiteDots(), aurora = try emblem.auroraDot()
        #expect(abs(white.centreY - middle.y) <= 0.5, "white dots at \(white.centreY), capsule middle at \(middle.y)")
        #expect(abs(aurora.centre.y - middle.y) <= 0.5,
                "aurora dot at \(aurora.centre.y), capsule middle at \(middle.y)")
    }

    @Test(arguments: [CGFloat(1), 1.4], [CGFloat(1), 2])
    func theInkIsCentredAcrossTheCapsule(scale: CGFloat, pixels: CGFloat) throws {
        let emblem = try EmblemPicture(scale: scale, pixels: pixels)
        let middle = try emblem.capsuleMiddle()
        let white = try emblem.whiteDots(), aurora = try emblem.auroraDot()
        let inkMiddle = (white.left + aurora.right) / 2
        #expect(abs(inkMiddle - middle.x) <= 0.5,
                "ink from \(white.left) to \(aurora.right), capsule middle at \(middle.x)")
    }

    @Test(arguments: [CGFloat(1), 1.4], [CGFloat(1), 2])
    func theGlowIsDrawnAroundTheAuroraDot(scale: CGFloat, pixels: CGFloat) throws {
        let emblem = try EmblemPicture(scale: scale, pixels: pixels)
        let aurora = try emblem.auroraDot()
        // Just outside the dot, short of its white neighbour.
        let distance = aurora.radius * 1.3
        let centre = aurora.centre
        func glow(_ dx: Double, _ dy: Double, by extra: Double = 0) -> Double {
            let length = distance + extra
            return emblem.picture.sample(x: centre.x + dx * length, y: centre.y + dy * length).green
        }
        let directions: [(Double, Double)] = [(0, -1), (0, 1), (-1, 0), (1, 0)]
        let up = glow(0, -1), down = glow(0, 1), left = glow(-1, 0), right = glow(1, 0)
        // How much the glow changes over a pixel here: a glow off centre by half a pixel would make a pair of
        // opposite readings differ by this much.
        let slope = directions.map { glow($0.0, $0.1, by: -0.5) - glow($0.0, $0.1, by: 0.5) }.reduce(0, +) / 4
        let quantum = 2.0 / 255
        #expect(min(up, down, left, right) > emblem.pill.green + 0.03, "no glow around the aurora dot")
        #expect(slope > 0, "the glow does not fade away from the dot")
        #expect(abs(up - down) <= slope + quantum, "above \(up), below \(down)")
        #expect(abs(left - right) <= slope + quantum, "left \(left), right \(right)")
        #expect(abs((up + down) / 2 - (left + right) / 2) <= slope / 2 + quantum,
                "above and below \((up + down) / 2), either side \((left + right) / 2)")
    }
}

/// The emblem rendered off screen on a white field, and what can be read from its pixels. Positions are in pixels from
/// the picture's top-left corner; pixel (i, j) covers [i, i + 1) × [j, j + 1).
@MainActor
private struct EmblemPicture {
    let picture: Picture
    /// The capsule's own colour, the commonest colour inside it.
    let pill: Picture.Colour
    let background: Picture.Colour
    /// The smallest box of pixels holding the capsule.
    let box: (minX: Int, maxX: Int, minY: Int, maxY: Int)

    init(scale: CGFloat, pixels: CGFloat) throws {
        let size = CGSize(width: (160 * scale).rounded(), height: (64 * scale).rounded())
        let scene = SnapshotScene(name: "emblem", size: size, background: RGB(1, 1, 1)) { MarkEmblem(scale: scale) }
        let picture = try Picture(try #require(SnapshotRenderer.png(of: scene, scale: pixels)))
        let dark = picture.indices.filter { picture[$0.x, $0.y].lightness < 0.5 }
        let box = (minX: try #require(dark.map(\.x).min()), maxX: try #require(dark.map(\.x).max()),
                   minY: try #require(dark.map(\.y).min()), maxY: try #require(dark.map(\.y).max()))
        var counts: [Picture.Colour: Int] = [:]
        for y in box.minY ... box.maxY {
            for x in box.minX ... box.maxX { counts[picture[x, y], default: 0] += 1 }
        }
        self.picture = picture
        self.box = box
        background = picture[0, 0]
        pill = try #require(counts.max { $0.value < $1.value }?.key)
    }

    /// How much of the capsule a pixel shows, from 0 (the white field) to 1 (the capsule's colour).
    private func coverage(_ colour: Picture.Colour) -> Double {
        min(1, max(0, (background.lightness - colour.lightness) / (background.lightness - pill.lightness)))
    }

    /// Whether `colour` is the capsule's own colour, with nothing drawn on it.
    private func isBare(_ colour: Picture.Colour) -> Bool { colour.distance(to: pill) <= 3.0 / 255 }

    /// The run of bare capsule along a line of pixels, if the line crosses the capsule with nothing drawn on it.
    private func bareRun(_ line: [Picture.Colour]) -> ClosedRange<Int>? {
        guard let first = line.firstIndex(where: isBare), let last = line.lastIndex(where: isBare),
              line[first ... last].allSatisfy(isBare) else { return nil }
        return first ... last
    }

    /// Where a line's coverage is centred: the middle of the capsule along it, since the capsule is symmetric.
    private func centre(of line: [Picture.Colour], from start: Int) -> Double {
        var total = 0.0, sum = 0.0
        for (index, colour) in line.enumerated() {
            let weight = coverage(colour)
            total += weight
            sum += weight * (Double(start + index) + 0.5)
        }
        return sum / total
    }

    /// The capsule's middle, from the lines across it that nothing is drawn on: columns beside the mark for its
    /// height, rows above or below the mark and its glow for its width.
    func capsuleMiddle() throws -> CGPoint {
        let rows = Array(box.minY ... box.maxY), columns = Array(box.minX ... box.maxX)
        let ys = columns.compactMap { x -> Double? in
            let line = rows.map { picture[x, $0] }
            guard let run = bareRun(line), run.count * 2 >= line.count else { return nil }
            return centre(of: line, from: box.minY)
        }
        let xs = rows.compactMap { y -> Double? in
            let line = columns.map { picture[$0, y] }
            guard let run = bareRun(line), run.count * 2 >= line.count else { return nil }
            return centre(of: line, from: box.minX)
        }
        try #require(ys.count >= 3 && xs.count >= 3, "too few clear lines across the capsule")
        return CGPoint(x: xs.reduce(0, +) / Double(xs.count), y: ys.reduce(0, +) / Double(ys.count))
    }

    /// How strongly a pixel shows aurora: green over red, above what the glow alone reaches at the dot's rim.
    private func auroraWeight(_ colour: Picture.Colour) -> Double { max(0, colour.green - colour.red - 0.15) }

    /// The aurora dot: its centre and radius, and its right edge, which is the right edge of the mark's ink.
    func auroraDot() throws -> (centre: CGPoint, radius: Double, right: Double) {
        var total = 0.0, sumX = 0.0, sumY = 0.0
        for y in box.minY ... box.maxY {
            for x in box.minX ... box.maxX {
                let weight = auroraWeight(picture[x, y])
                total += weight
                sumX += weight * (Double(x) + 0.5)
                sumY += weight * (Double(y) + 0.5)
            }
        }
        try #require(total > 0, "no aurora dot")
        let centre = CGPoint(x: sumX / total, y: sumY / total)
        // The radius from the chord through the row that holds the centre: the sum of how much of each pixel the dot
        // covers. Beside the dot only the glow shows, so the pixels just past each end say how much green there is
        // not the dot's.
        let row = Int(centre.y.rounded(.down))
        let inside = (box.minX ... box.maxX).filter { auroraWeight(picture[$0, row]) > 0 }
        let first = try #require(inside.first), last = try #require(inside.last)
        let full = try #require((first ... last).map { picture[$0, row].greenness }.max())
        let glowLeft = picture[first - 2, row].greenness / full, glowRight = picture[last + 2, row].greenness / full
        let chord = ((first - 1) ... (last + 1)).map { x -> Double in
            let glow = Double(x) < centre.x ? glowLeft : glowRight
            return min(1, max(0, (picture[x, row].greenness / full - glow) / (1 - glow)))
        }.reduce(0, +)
        let offset = Double(row) + 0.5 - centre.y
        let radius = (chord * chord / 4 + offset * offset).squareRoot()
        return (centre, radius, centre.x + radius)
    }

    /// How strongly a pixel shows a white dot: its darkest channel above the capsule's, where it has no colour of its
    /// own. Only pixels between a column's top and bottom edges count, so the hairline does not.
    private func whiteWeight(_ colour: Picture.Colour) -> Double {
        colour.chroma < 0.06 ? max(0, colour.darkest - pill.darkest - 2.0 / 255) : 0
    }

    /// The white dots: the height of their centres, and the left edge of the leftmost, which is the left edge of the
    /// mark's ink.
    func whiteDots() throws -> (centreY: Double, left: Double) {
        let aurora = try auroraDot()
        let end = Int((aurora.centre.x - aurora.radius).rounded(.down)) - 1
        var total = 0.0, sumY = 0.0
        for x in box.minX ... end {
            let line = (box.minY ... box.maxY).map { picture[x, $0] }
            guard let first = line.firstIndex(where: isBare), let last = line.lastIndex(where: isBare) else { continue }
            for index in first ... last {
                let weight = whiteWeight(line[index])
                total += weight
                sumY += weight * (Double(box.minY + index) + 0.5)
            }
        }
        try #require(total > 0, "no white dots")
        let centreY = sumY / total
        // Along the row through the centres, from inside the capsule's hairline to the first dot.
        let row = Int(centreY.rounded(.down))
        let start = try #require((box.minX ... end).first { isBare(picture[$0, row]) })
        let weights = (start ... end).map { whiteWeight(picture[$0, row]) }
        let first = try #require(weights.firstIndex { $0 > 0 })
        let full = try #require(weights[first ..< min(first + 3, weights.count)].max())
        let left = Double(start + first) + 1 - weights[first] / full
        return (centreY, left)
    }
}

/// A PNG's pixels as colours from 0 to 1.
private struct Picture {
    struct Colour: Hashable {
        let red: Double, green: Double, blue: Double

        var lightness: Double { (red + green + blue) / 3 }
        var darkest: Double { min(red, green, blue) }
        var chroma: Double { max(red, green, blue) - darkest }
        /// Green over red: aurora has much more of it than white ink, the capsule or the field.
        var greenness: Double { green - red }
        func distance(to other: Colour) -> Double {
            max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
        }
    }

    let width: Int, height: Int
    private let colours: [Colour]

    init(_ png: Data) throws {
        let bitmap = try #require(NSBitmapImageRep(data: png))
        try #require(bitmap.bitsPerSample == 8 && bitmap.samplesPerPixel >= 3)
        width = bitmap.pixelsWide
        height = bitmap.pixelsHigh
        var colours: [Colour] = []
        colours.reserveCapacity(width * height)
        var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        for y in 0 ..< height {
            for x in 0 ..< width {
                bitmap.getPixel(&pixel, atX: x, y: y)
                colours.append(Colour(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255,
                                      blue: Double(pixel[2]) / 255))
            }
        }
        self.colours = colours
    }

    subscript(x: Int, y: Int) -> Colour { colours[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)] }

    var indices: [(x: Int, y: Int)] { (0 ..< height).flatMap { y in (0 ..< width).map { (x: $0, y: y) } } }

    /// The colour at a point between pixel centres, blended from the four nearest.
    func sample(x: Double, y: Double) -> Colour {
        let u = x - 0.5, v = y - 0.5
        let x0 = Int(u.rounded(.down)), y0 = Int(v.rounded(.down))
        let s = u - Double(x0), t = v - Double(y0)
        func mix(_ a: Colour, _ b: Colour, _ f: Double) -> Colour {
            Colour(red: a.red + (b.red - a.red) * f, green: a.green + (b.green - a.green) * f,
                   blue: a.blue + (b.blue - a.blue) * f)
        }
        return mix(mix(self[x0, y0], self[x0 + 1, y0], s), mix(self[x0, y0 + 1], self[x0 + 1, y0 + 1], s), t)
    }
}
