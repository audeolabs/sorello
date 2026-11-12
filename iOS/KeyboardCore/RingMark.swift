import Foundation

/// The ring mark (ARCHITECTURE.md, "Keyboard look"), on the 27-unit square it was drawn on: seven white dots of one size
/// round a ring that is open at the bottom, and a larger eighth, the state dot, which carries the state's colour. It is
/// the one mark the app draws inside itself (Home, onboarding, the keyboard's Start and menu, the Live Activity); it is
/// not the app icon's mark, which is Sorello's row of dots. Angles run round the ring from its bottom, up its right side:
/// the dot at angle `a` is at `(centre.x + radius * sin a, centre.y + radius * cos a)`, y downward. Pure.
enum RingMark {
    struct Point: Equatable, Sendable {
        var x: Double
        var y: Double
    }

    /// The mark fitted into a box, in the box's coordinates: the state dot, and the seven white dots in order from it.
    struct Fitted: Equatable, Sendable {
        var stateDot: Point
        var stateRadius: Double
        var whiteDots: [Point]
        var whiteRadius: Double
    }

    /// The square the mark is drawn on, in its units, and the ring's radius about its centre.
    static let side = 27.0
    static let ringRadius = 9.3
    /// The state dot: always the largest, a little left of the bottom.
    static let stateRadius = 3.1
    static let stateAngle = 327.0
    /// The white dots, one size, each `whiteSpacing` degrees on from the one before, starting from the state dot.
    static let whiteRadius = 2.05
    static let whiteSpacing = 42.0
    static let whiteCount = 7
    /// The white dots' angles, in order from the state dot.
    static let whiteAngles = (1 ... whiteCount).map { stateAngle - whiteSpacing * Double($0) }
    /// The white dots are the surface's ink at this strength.
    static let whiteStrength = 0.8

    /// The mark scaled to `box`'s shorter side and centred there: one scale, never distorted.
    static func fitted(in box: KeyRect) -> Fitted {
        let scale = max(0, min(box.width, box.height)) / side
        let radius = ringRadius * scale
        func place(_ degrees: Double) -> Point {
            let angle = degrees * .pi / 180
            return Point(x: box.midX + radius * sin(angle), y: box.midY + radius * cos(angle))
        }
        return Fitted(stateDot: place(stateAngle), stateRadius: stateRadius * scale, whiteDots: whiteAngles.map(place),
                      whiteRadius: whiteRadius * scale)
    }
}
