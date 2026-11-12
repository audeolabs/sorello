import Foundation

/// The opening (ARCHITECTURE.md, "Keyboard look", "The opening"): Start's ring becomes the recording's row, from its
/// first moment, the ring, to its last, the calm row, in islands as the keyboard lays them out.
enum RingOpeningTests {
    static let tests: [TestCase] = [
        ("startsAsTheRingAndEndsAsTheRow", testStartsAsTheRingAndEndsAsTheRow),
        ("progressClampsAndNotANumberRests", testProgressClampsAndNotANumberRests),
        ("staysInsideTheIslandAndNoDotsTouch", testStaysInsideTheIslandAndNoDotsTouch),
        ("stateDotNeverJumps", testStateDotNeverJumps),
        ("stateDotStaysAtTheRowsEnd", testStateDotStaysAtTheRowsEnd),
        ("rowLiftsToTheMiddleLineInTheFirstThird", testRowLiftsToTheMiddleLineInTheFirstThird),
        ("whiteDotsKeepTheRingsSpacingAtFirst", testWhiteDotsKeepTheRingsSpacingAtFirst),
        ("joiningDotsBrightenInTheSecondHalf", testJoiningDotsBrightenInTheSecondHalf),
        ("mirroredIsTheMirrorImage", testMirroredIsTheMirrorImage),
        ("opensOnlyIntoSevenDotsOrMore", testOpensOnlyIntoSevenDotsOrMore),
    ]

    /// An island as the keyboard lays it out (`DictationBarView`), in the recording island's coordinates: x from 0 to its
    /// width, y from 0 to the control's height. Start, at the island's fixed end (the right; the left left-handed),
    /// holds the 19-point mark and "Start" 6 points apart, centred, the mark towards the middle; the recording holds the
    /// wave, the time and the 10-point stop glyph, 8 points apart, inside 12 points of padding on the wave's side and 14
    /// on the stop glyph's. Left-handed, every part is the mirror image.
    private struct Scene: CustomStringConvertible {
        var height: Double
        var width: Double
        var label: Double
        var time: Double
        var mirrored = false

        var startWidth: Double { IslandLayout.startWidth(labelWidth: label + 2, controlHeight: height) }
        var waveHeight: Double { min(24, height - 12) }

        func reflect(_ x: Double) -> Double { mirrored ? width - x : x }

        /// Start's mark box.
        var ring: KeyRect {
            let content = 19 + 6 + label
            let x = width - startWidth + (startWidth - content) / 2
            return KeyRect(x: mirrored ? width - x - 19 : x, y: (height - 19) / 2, width: 19, height: 19)
        }

        /// The wave's box.
        var waveBox: KeyRect {
            let w = width - 12 - 14 - 10 - 8 - 8 - time
            return KeyRect(x: mirrored ? width - 12 - w : 12, y: (height - waveHeight) / 2, width: w, height: waveHeight)
        }

        /// The wave as `DotFieldView` draws it, at `level` (0 is the calm row), mirrored across its box left-handed.
        func wave(level: Double = 0) -> (row: [DotWave.Dot], mark: DotWave.Dot) {
            let box = waveBox
            func place(_ dot: DotWave.Dot) -> DotWave.Dot {
                DotWave.Dot(x: box.x + (mirrored ? box.width - dot.x : dot.x), y: box.y + dot.y, radius: dot.radius,
                            brightness: dot.brightness)
            }
            return (DotWave.dots(level: level, width: box.width, height: box.height).map(place),
                    place(DotWave.markDot(level: level, width: box.width, height: box.height)))
        }

        func frame(_ progress: Double, level: Double = 0, resting: RingOpening.End = .ring) -> RingOpening.Frame {
            let wave = wave(level: level)
            return RingOpening.frame(ring: ring, row: wave.row, mark: wave.mark, progress: progress, mirrored: mirrored,
                                     resting: resting)
        }

        var description: String {
            "\(height) pt \(width) wide, label \(label), time \(time)\(mirrored ? ", left-handed" : "")"
        }
    }

    /// The control heights (portrait and landscape), the recording island on the 375 pt and 402 pt phones and in
    /// landscape, and "Start" and the time at small, default and large text sizes, in either hand.
    private static let scenes: [Scene] = [38.0, 32.0].flatMap { height in
        [147.0, 161.0, 200.0].flatMap { width in
            [(30.0, 22.0), (37.0, 25.0), (50.0, 33.0)].flatMap { label, time in
                [false, true].map { Scene(height: height, width: width, label: label, time: time, mirrored: $0) }
            }
        }
    }

    /// The mark Start draws, mirrored across its box left-handed.
    private static func startRing(_ scene: Scene) -> (state: DotWave.Dot, white: [DotWave.Dot]) {
        let box = scene.ring
        let mark = RingMark.fitted(in: box)
        func place(_ point: RingMark.Point, _ radius: Double, _ strength: Double) -> DotWave.Dot {
            DotWave.Dot(x: scene.mirrored ? 2 * box.midX - point.x : point.x, y: point.y, radius: radius, brightness: strength)
        }
        return (place(mark.stateDot, mark.stateRadius, 1),
                mark.whiteDots.map { place($0, mark.whiteRadius, RingMark.whiteStrength) })
    }

    private static func distance(_ a: DotWave.Dot, _ b: DotWave.Dot) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    private static func near(_ a: DotWave.Dot, _ b: DotWave.Dot, _ tolerance: Double) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.radius - b.radius) <= tolerance
            && abs(a.brightness - b.brightness) <= tolerance
    }

    /// The dots that show: the state dot and every dot with some strength.
    private static func shown(_ frame: RingOpening.Frame) -> [DotWave.Dot] {
        [frame.stateDot] + frame.dots.filter { $0.brightness > 0 }
    }

    /// The progress over 0.65 s, in steps of 1/1000 s.
    private static let steps = (0 ... 650).map { Double($0) / 650 }

    /// At its first moment the string is the ring, dot for dot as Start draws it (centres, radii, the white dots at
    /// 80%), and nothing else shows; at its last it is the wave's calm row and the dot it settles into, dot for dot, the
    /// white dots the seven of the row nearest that dot. Just after the first moment and just before the last it is
    /// within a hair of them, so neither end jumps.
    private static func testStartsAsTheRingAndEndsAsTheRow() {
        for scene in scenes {
            let ring = startRing(scene), wave = scene.wave()
            TestSupport.expect(RingOpening.applies(rowCount: wave.row.count), "\(scene): fewer than seven dots")
            let first = scene.frame(0)
            TestSupport.expectEqual(first.stateDot, ring.state)
            TestSupport.expectEqual(Array(first.dots.prefix(7)), ring.white)
            TestSupport.expectEqual(shown(first).count, 8)
            TestSupport.expectEqual(first.dots.count, wave.row.count)

            let last = scene.frame(1)
            TestSupport.expectEqual(last.stateDot, wave.mark)
            let nearest = wave.row.sorted { abs($0.x - wave.mark.x) < abs($1.x - wave.mark.x) }
            TestSupport.expectEqual(last.dots, nearest)
            TestSupport.expectEqual(last.rowLevel, wave.mark.y)

            let justAfter = scene.frame(1e-6), justBefore = scene.frame(1 - 1e-6)
            TestSupport.expect(near(justAfter.stateDot, ring.state, 1e-3), "\(scene): the first moment jumps")
            TestSupport.expect(near(justBefore.stateDot, wave.mark, 1e-3), "\(scene): the last moment jumps")
            for (dot, white) in zip(justAfter.dots, ring.white) {
                TestSupport.expect(near(dot, white, 1e-3), "\(scene): a white dot jumps from the ring: \(dot), \(white)")
            }
            for (dot, target) in zip(justBefore.dots, nearest) {
                TestSupport.expect(near(dot, target, 1e-3), "\(scene): a dot jumps into the row: \(dot), \(target)")
            }
        }
    }

    /// Progress outside 0...1 is the nearer end; a progress that is not a number is the end the caller asked for.
    private static func testProgressClampsAndNotANumberRests() {
        let scene = scenes[0]
        TestSupport.expectEqual(scene.frame(-0.5), scene.frame(0))
        TestSupport.expectEqual(scene.frame(-.infinity), scene.frame(0))
        TestSupport.expectEqual(scene.frame(1.5), scene.frame(1))
        TestSupport.expectEqual(scene.frame(.infinity), scene.frame(1))
        TestSupport.expectEqual(scene.frame(.nan, resting: .ring), scene.frame(0))
        TestSupport.expectEqual(scene.frame(.nan, resting: .row), scene.frame(1))
        TestSupport.expectEqual(RingOpening.eased(0), 0)
        TestSupport.expectEqual(RingOpening.eased(0.5), 0.5)
        TestSupport.expectEqual(RingOpening.eased(1), 1)
    }

    /// At every moment no dot's ink leaves the recording island's capsule (its height, and its rounded ends), and no two
    /// shown dots touch: with the calm row, and with the row lifted by a loud voice (if the recording begins before the
    /// opening ends, the row it opens into shows the voice).
    private static func testStaysInsideTheIslandAndNoDotsTouch() {
        for scene in scenes {
            for level in [0.0, 1.0] {
                for progress in steps {
                    let dots = shown(scene.frame(progress, level: level))
                    let half = scene.height / 2
                    for dot in dots {
                        // The capsule: within half its height of the segment joining its two ends' centres.
                        let x = min(max(dot.x, half), scene.width - half)
                        let reach = ((dot.x - x) * (dot.x - x) + (dot.y - half) * (dot.y - half)).squareRoot() + dot.radius
                        TestSupport.expect(reach < half, "\(scene), level \(level), at \(progress): a dot leaves the island: \(dot)")
                    }
                    for i in dots.indices {
                        for j in dots.indices where j > i {
                            let gap = distance(dots[i], dots[j]) - dots[i].radius - dots[j].radius
                            TestSupport.expect(gap > 0, "\(scene), level \(level), at \(progress): dots \(i) and \(j) touch: \(gap)")
                        }
                    }
                }
            }
        }
    }

    /// The state dot moves without a jump: under 3 points in any 1/60 s of the opening (turning over the ring's top at
    /// the eased progress's quickest, it moves about 1.9).
    private static func testStateDotNeverJumps() {
        let frame = 1.0 / 60 / RingOpening.duration
        for scene in scenes {
            for progress in steps {
                let a = scene.frame(progress).stateDot, b = scene.frame(min(progress + frame, 1)).stateDot
                TestSupport.expect(distance(a, b) < 3, "\(scene), at \(progress): the state dot jumps \(distance(a, b))")
            }
        }
    }

    /// The state dot comes over the ring's top and down to the row's end, where the wave will have it, and stays there:
    /// once it is level with the row (`turn` a quarter round from the dip's bottom), it is on the mark's dot.
    private static func testStateDotStaysAtTheRowsEnd() {
        let settled = 1 - 90 / RingMark.stateAngle
        for scene in scenes {
            let mark = scene.wave().mark
            for progress in steps where RingOpening.eased(progress) >= settled {
                let dot = scene.frame(progress).stateDot
                TestSupport.expect(abs(dot.x - mark.x) < 1e-9 && abs(dot.y - mark.y) < 1e-9,
                                   "\(scene), at \(progress): the state dot is at \(dot), not on the mark's dot")
            }
        }
    }

    /// The row lies along a level that lifts from the ring's bottom to the island's middle line in the first third: on
    /// the middle line from an eased progress of 0.35 on, and between the two before.
    private static func testRowLiftsToTheMiddleLineInTheFirstThird() {
        for scene in scenes {
            let middle = scene.wave().mark.y
            TestSupport.expect(abs(middle - scene.height / 2) < 1e-9, "\(scene): the row is not on the middle line")
            let bottom = scene.ring.midY + RingMark.ringRadius * 19 / RingMark.side
            TestSupport.expect(abs(scene.frame(0).rowLevel - bottom) < 1e-9, "\(scene): the row starts off the ring's bottom")
            var last = bottom
            for progress in steps {
                let level = scene.frame(progress).rowLevel
                if RingOpening.eased(progress) >= RingOpening.lifted {
                    TestSupport.expectEqual(level, middle)
                } else {
                    TestSupport.expect(level <= last && level >= middle, "\(scene), at \(progress): the row's level \(level)")
                }
                last = level
            }
        }
    }

    /// The white dots keep the ring's spacing while the ring first turns, so the last of them is never pushed across the
    /// ring's opening into the state dot: while the ring turns in place (the first tenth of the time) the last white dot
    /// is no nearer the state dot than on the ring, and at no moment does it come within 90% of that distance.
    private static func testWhiteDotsKeepTheRingsSpacingAtFirst() {
        for scene in scenes {
            let ring = startRing(scene)
            let onRing = distance(ring.state, ring.white[6])
            for progress in steps {
                let frame = scene.frame(progress)
                let apart = distance(frame.stateDot, frame.dots[6])
                if progress <= 0.1 {
                    TestSupport.expect(apart > onRing - 0.01, "\(scene), at \(progress): the last white dot nears the state dot: \(apart)")
                }
                TestSupport.expect(apart > 0.9 * onRing, "\(scene), at \(progress): the last white dot is pushed at the state dot: \(apart)")
            }
        }
    }

    /// The row's other dots join on behind the seventh, a pitch apart along the string, unseen over the first half and
    /// brightening to the row's strength over the second, at the row's size.
    private static func testJoiningDotsBrightenInTheSecondHalf() {
        for scene in scenes {
            let row = scene.wave().row
            for progress in steps {
                let frame = scene.frame(progress), e = RingOpening.eased(progress)
                for dot in frame.dots.dropFirst(7) {
                    TestSupport.expectEqual(dot.radius, DotWave.restRadius)
                    if e <= 0.45 { TestSupport.expectEqual(dot.brightness, 0) }
                    TestSupport.expect(dot.brightness <= DotWave.restBrightness, "\(scene), at \(progress): a joining dot is too bright")
                }
                if progress > 0, progress < 1, row.count > 8 {
                    // On the row's level, a pitch apart, once the string there has lifted to it.
                    let a = frame.dots[7], b = frame.dots[8]
                    if a.y == frame.rowLevel, b.y == frame.rowLevel {
                        TestSupport.expect(abs(abs(a.x - b.x) - DotWave.pitch) < 1e-6, "\(scene), at \(progress): joining dots \(abs(a.x - b.x)) apart")
                    }
                }
            }
        }
    }

    /// Left-handed the opening is the exact mirror image: the mirrored scene's frames are the right-handed frames
    /// reflected across the island's middle, dot for dot.
    private static func testMirroredIsTheMirrorImage() {
        for scene in scenes where !scene.mirrored {
            var mirrored = scene
            mirrored.mirrored = true
            for progress in stride(from: 0.0, through: 1.0, by: 0.01) {
                let right = scene.frame(progress), left = mirrored.frame(progress)
                func reflected(_ dot: DotWave.Dot) -> DotWave.Dot {
                    DotWave.Dot(x: scene.width - dot.x, y: dot.y, radius: dot.radius, brightness: dot.brightness)
                }
                TestSupport.expect(near(left.stateDot, reflected(right.stateDot), 1e-9), "\(scene), at \(progress): the state dot")
                TestSupport.expectEqual(left.dots.count, right.dots.count)
                for (l, r) in zip(left.dots, right.dots) {
                    TestSupport.expect(near(l, reflected(r), 1e-9), "\(scene), at \(progress): a dot is not mirrored")
                }
                TestSupport.expect(abs(left.rowLevel - right.rowLevel) < 1e-9, "\(scene), at \(progress): the row's level")
            }
        }
    }

    /// The opening needs a row of at least seven dots, one for each of the ring's white dots. In a narrower island
    /// there is none: the ring until the end, then the row, as Start hands over without it.
    private static func testOpensOnlyIntoSevenDotsOrMore() {
        TestSupport.expect(!RingOpening.applies(rowCount: 0), "an empty row opens")
        TestSupport.expect(!RingOpening.applies(rowCount: 6), "six dots open")
        TestSupport.expect(RingOpening.applies(rowCount: 7), "seven dots do not open")
        TestSupport.expect(RingOpening.applies(rowCount: 20), "twenty dots do not open")

        // An island too narrow for seven dots.
        for mirrored in [false, true] {
            let narrow = Scene(height: 38, width: 110, label: 37, time: 25, mirrored: mirrored)
            let wave = narrow.wave()
            TestSupport.expect(!wave.row.isEmpty && !RingOpening.applies(rowCount: wave.row.count), "the narrow island has \(wave.row.count) dots")
            let ring = startRing(narrow)
            for progress in [0, 0.3, 0.7, 0.999] {
                let frame = narrow.frame(progress)
                TestSupport.expectEqual(frame.stateDot, ring.state)
                TestSupport.expectEqual(frame.dots, ring.white)
            }
            TestSupport.expectEqual(narrow.frame(1).stateDot, wave.mark)
            TestSupport.expectEqual(narrow.frame(1).dots.count, wave.row.count)
        }
    }
}
