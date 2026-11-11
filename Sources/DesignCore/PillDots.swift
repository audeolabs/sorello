import CoreGraphics
import Foundation

/// The pill's dots in the screen's points (ARCHITECTURE.md, section 8, "Listening" and "Waiting"): the wave and its
/// aurora dot in the leading wing, and the wait's shimmer, which beside a housing runs through both wings as one row
/// and passes behind the housing. The pill draws exactly these, so what is drawn where can be tested here.
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

    /// The wait's row in `leading` and, beside a housing, `trailing`: laid out as one row over both and the gap
    /// between them, so its dots stay a pitch apart across the housing, with the dots that would fall outside the two
    /// boxes left out. The spot is at `sweep` along the whole row (`DotWave.sweep`); `still` (Reduce Motion) lights
    /// only the row's middle instead: its middle dot, or beside a housing the dot nearest it on each side.
    public static func shimmer(leading: CGRect, trailing: CGRect?, sweep: Double, still: Bool) -> [DotWave.Dot] {
        let minX = Double(leading.minX), maxX = Double((trailing ?? leading).maxX)
        let height = Double(leading.height)
        let xs = DotWave.row(width: maxX - minX, height: height).map { $0 + minX }
        let boxes = [leading] + (trailing.map { [$0] } ?? [])
        let r = DotWave.fullRadius
        let visible = xs.filter { x in
            boxes.contains { x - r >= Double($0.minX) - 1e-9 && x + r <= Double($0.maxX) + 1e-9 }
        }
        guard visible.count >= 2 else { return [] }
        let all = DotWave.shimmer(sweep: still ? -1 : sweep, row: xs, height: height)
        var dots = all.filter { dot in visible.contains(dot.x) }.map {
            DotWave.Dot(x: $0.x, y: $0.y + Double(leading.minY), radius: $0.radius, brightness: $0.brightness)
        }
        if still {
            let middle = (minX + maxX) / 2
            let lit = DotWave.shimmer(sweep: 0.5, row: [middle - 1, middle, middle + 1], height: height)[1]
            // One row: its middle dot. A row the housing interrupts: the dot beside the housing on each side.
            for side in trailing == nil ? [0.0] : [-1.0, 1.0] {
                let candidates = dots.indices.filter { (dots[$0].x - middle) * side >= 0 }
                if let nearest = candidates.min(by: { abs(dots[$0].x - middle) < abs(dots[$1].x - middle) }) {
                    dots[nearest].radius = lit.radius
                    dots[nearest].brightness = lit.brightness
                }
            }
        }
        return dots
    }

    private static func moved(_ dot: DotWave.Dot, by box: CGRect) -> DotWave.Dot {
        DotWave.Dot(x: dot.x + Double(box.minX), y: dot.y + Double(box.minY), radius: dot.radius,
                    brightness: dot.brightness)
    }
}
