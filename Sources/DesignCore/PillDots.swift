import CoreGraphics
import Foundation

/// The pill's dots in the screen's points (ARCHITECTURE.md, section 8, "Listening" and "Waiting"): the wave and its
/// aurora dot, and the wait's shimmer. The pill draws exactly these, so what is drawn where can be tested here.
public enum PillDots {
    /// The wave and its aurora dot in `box`, for the voice in `trace` at `now`, or, `still`, held at `level` (Reduce
    /// Motion). Empty, with no aurora dot, when the box has no room.
    public static func wave(in box: CGRect, trace: DotWave.Trace, now: Double, level: Double,
                            still: Bool) -> (dots: [DotWave.Dot], mark: DotWave.Dot?) {
        let width = Double(box.width), height = Double(box.height)
        let local = still ? DotWave.dots(level: level, width: width, height: height)
            : DotWave.dots(trace: trace, now: now, width: width, height: height)
        guard !local.isEmpty else { return ([], nil) }
        let mark = DotWave.markDot(level: level, width: width, height: height)
        return (local.map { moved($0, by: box) }, moved(mark, by: box))
    }

    /// The wait's row in `box`, with its spot at `sweep` along it (`DotWave.sweep`); `still` (Reduce Motion) lights
    /// only its middle dot instead. Empty when the box has no room for a row.
    public static func shimmer(in box: CGRect, sweep: Double, still: Bool) -> [DotWave.Dot] {
        let height = Double(box.height)
        let xs = DotWave.row(width: Double(box.width), height: height)
        guard xs.count >= 2 else { return [] }
        var dots = DotWave.shimmer(sweep: still ? -1 : sweep, row: xs, height: height).map { moved($0, by: box) }
        if still {
            let middle = Double(box.midX)
            let lit = DotWave.shimmer(sweep: 0.5, row: [middle - 1, middle, middle + 1], height: height)[1]
            if let nearest = dots.indices.min(by: { abs(dots[$0].x - middle) < abs(dots[$1].x - middle) }) {
                dots[nearest].radius = lit.radius
                dots[nearest].brightness = lit.brightness
            }
        }
        return dots
    }

    private static func moved(_ dot: DotWave.Dot, by box: CGRect) -> DotWave.Dot {
        DotWave.Dot(x: dot.x + Double(box.minX), y: dot.y + Double(box.minY), radius: dot.radius,
                    brightness: dot.brightness)
    }
}
