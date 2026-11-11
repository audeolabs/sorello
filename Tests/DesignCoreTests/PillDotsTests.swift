import CoreGraphics
import DesignCore
import Foundation
import Testing

/// ARCHITECTURE.md, section 8: the dots the pill draws, in the screen's points.
@Suite struct PillDotsTests {
    static let screens = [PillGeometryTests.island, PillGeometryTests.notch, PillGeometryTests.external,
                          PillGeometryTests.islandAt1x, PillGeometryTests.narrowIsland]

    static func inside(_ dot: DotWave.Dot, _ box: CGRect) -> Bool {
        dot.x - dot.radius >= Double(box.minX) - 1e-9 && dot.x + dot.radius <= Double(box.maxX) + 1e-9
            && dot.y - dot.radius >= Double(box.minY) - 1e-9 && dot.y + dot.radius <= Double(box.maxY) + 1e-9
    }

    /// The wave lies in its box on the body's middle line and ends in the aurora dot, at the end of its box, before
    /// the time.
    @Test func theWaveEndsInTheAuroraDotBeforeTheTime() throws {
        var trace = DotWave.Trace()
        for frame in 0 ... 60 { trace.record(Double(frame % 7) / 7, at: Double(frame) / 60) }
        for screen in Self.screens {
            let layout = PillGeometry.layout(.listening(trailing: 30, cancel: false), on: screen)
            let box = try #require(layout.leading), time = try #require(layout.trailing)
            for still in [false, true] {
                let wave = PillDots.wave(in: box, trace: trace, now: 1, level: 0.7, still: still)
                let mark = try #require(wave.mark)
                #expect(wave.dots.count >= 10)
                for dot in wave.dots + [mark] {
                    #expect(Self.inside(dot, box))
                    #expect(abs(dot.y - Double(layout.body.frame.midY)) < 1e-9)
                }
                #expect(mark.x > (wave.dots.map(\.x).max() ?? 0))
                #expect(Double(box.maxX) - (mark.x + mark.radius) <= 1)
                #expect(Double(time.minX) - (mark.x + mark.radius) >= PillGeometry.split)
            }
        }
        #expect(PillDots.wave(in: CGRect(x: 0, y: 0, width: 5, height: 30), trace: trace, now: 1, level: 1,
                              still: false).mark == nil)
    }

    /// The wait is one row in its box at an even pitch, centred, on the body's middle line; the spot sweeps it from
    /// left to right.
    @Test func theShimmerSweepsOneRow() throws {
        for screen in Self.screens {
            let layout = PillGeometry.layout(.waiting(trailing: nil), on: screen)
            let box = try #require(layout.leading)
            var brightestX: [Double] = []
            for sweep in stride(from: -0.3, through: 1.3, by: 0.05) {
                let dots = PillDots.shimmer(in: box, sweep: sweep, still: false)
                #expect(dots.count >= 6)
                for dot in dots {
                    #expect(Self.inside(dot, box))
                    #expect(abs(dot.y - Double(layout.body.frame.midY)) < 1e-9)
                }
                if let lit = dots.max(by: { $0.brightness < $1.brightness }), lit.brightness > 0.9 {
                    brightestX.append(lit.x)
                }
                let xs = dots.map(\.x)
                for (a, b) in zip(xs, xs.dropFirst()) {
                    #expect(abs(b - a - DotWave.pitch) < 1e-9, "the row's pitch breaks")
                }
                let first = try #require(xs.first), last = try #require(xs.last)
                #expect(abs((first - Double(box.minX)) - (Double(box.maxX) - last)) < 1e-9, "the row is off centre")
            }
            #expect(brightestX == brightestX.sorted(), "the spot does not sweep left to right")
            #expect(Set(brightestX).count >= 4)
        }
        #expect(PillDots.shimmer(in: CGRect(x: 0, y: 0, width: 8, height: 30), sweep: 0.5, still: false).isEmpty)
    }

    /// With Reduce Motion the wait is a still row with its middle dot lit, whatever the sweep.
    @Test func theStillWaitLightsItsMiddle() throws {
        for screen in Self.screens {
            let box = try #require(PillGeometry.layout(.waiting(trailing: nil), on: screen).leading)
            let dots = PillDots.shimmer(in: box, sweep: 0.2, still: true)
            let lit = dots.filter { $0.brightness > 0.9 }
            #expect(dots.filter { $0.brightness <= 0.45 + 1e-9 }.count == dots.count - lit.count)
            #expect(PillDots.shimmer(in: box, sweep: 0.9, still: true) == dots)
            #expect(lit.count == 1)
            let middle = Double(box.midX)
            let nearest = dots.min { abs($0.x - middle) < abs($1.x - middle) }
            #expect(lit.first?.x == nearest?.x)
        }
    }
}

/// ARCHITECTURE.md, section 8, "The mark": a short row of dots rising into the larger aurora dot.
@Suite struct SorelloMarkTests {
    @Test func theRowRisesIntoTheAuroraDot() throws {
        let row = SorelloMark.row
        #expect(row.count >= 3)
        for (a, b) in zip(row, row.dropFirst()) {
            #expect(b.radius > a.radius && b.brightness >= a.brightness)
            #expect(abs(b.x - a.x - a.radius - b.radius - SorelloMark.gap) < 1e-9, "uneven gaps")
        }
        let last = try #require(row.last)
        #expect(SorelloMark.accent.radius > last.radius)
        #expect(SorelloMark.accent.x - SorelloMark.accent.radius - last.x - last.radius > SorelloMark.gap)
        #expect((row + [SorelloMark.accent]).allSatisfy { $0.y == 0 })
    }

    /// Fitted into any box, the mark fills it along one side, centred, undistorted, and every dot stays inside.
    @Test func theMarkFitsItsBoxCentred() throws {
        for (w, h) in [(1024.0, 1024.0), (22.0, 16.0), (300.0, 20.0), (19.0, 19.0)] {
            for weight in [1.0, 1.4] {
                let mark = SorelloMark.fitted(x: 10, y: 20, width: w, height: h, weight: weight)
                let dots = mark.row + [mark.accent]
                let minX = try #require(dots.map { $0.x - $0.radius }.min())
                let maxX = try #require(dots.map { $0.x + $0.radius }.max())
                let minY = try #require(dots.map { $0.y - $0.radius }.min())
                let maxY = try #require(dots.map { $0.y + $0.radius }.max())
                #expect(minX >= 10 - 1e-9 && maxX <= 10 + w + 1e-9 && minY >= 20 - 1e-9 && maxY <= 20 + h + 1e-9)
                #expect(abs((minX + maxX) / 2 - (10 + w / 2)) < 1e-9 && abs((minY + maxY) / 2 - (20 + h / 2)) < 1e-9)
                #expect(abs(maxX - minX - w) < 1e-9 || abs(maxY - minY - h) < 1e-9)
                let first = try #require(mark.row.first), second = mark.row[1]
                #expect(abs(second.x - first.x - (SorelloMark.row[1].x - SorelloMark.row[0].x) * mark.scale) < 1e-9)
                #expect(abs(first.radius - SorelloMark.row[0].radius * weight * mark.scale) < 1e-9)
            }
        }
        let empty = SorelloMark.fitted(x: 0, y: 0, width: -5, height: .nan)
        #expect(empty.scale == 0)
    }
}

/// ARCHITECTURE.md, section 8: text meets 4.5:1 on its background and accents 3:1. The pill's colours are held to it.
@Suite struct PillPaletteTests {
    @Test func thePillsInkAndAccentsAreLegible() {
        let fill = Palette.pill
        #expect(RGB.contrast(Palette.ink, fill) >= 4.5)
        #expect(RGB.contrast(Palette.ink.blended(alpha: Palette.secondaryInkAlpha, over: fill), fill) >= 4.5)
        for accent in [Palette.aurora, Palette.glacier, Palette.ember, Palette.shimmer] {
            #expect(RGB.contrast(accent, fill) >= 3)
        }
        // The wave's resting dots are still a visible row.
        #expect(RGB.contrast(Palette.ink.blended(alpha: DotWave.restBrightness, over: fill), fill) >= 3)
        // The hairline sets the pill off from a dark screen.
        #expect(RGB.contrast(Palette.edge, Palette.screen) >= 3)
    }
}
