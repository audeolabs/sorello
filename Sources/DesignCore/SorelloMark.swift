import Foundation

/// The Sorello mark (ARCHITECTURE.md, section 8, "The mark"): the wave coming to rest, a short row of dots that grow
/// and brighten into the larger aurora dot. The app icon, the menu-bar icon and the mark in the app all draw it from
/// here.
public enum SorelloMark {
    /// One dot of the mark: its centre, radius and brightness (0 to 1) in the units it is given in.
    public struct Dot: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var radius: Double
        public var brightness: Double

        public init(x: Double, y: Double, radius: Double, brightness: Double) {
            self.x = x
            self.y = y
            self.radius = radius
            self.brightness = brightness
        }
    }

    /// The white dots, left to right, in the mark's units: the wave's pitch, rising from a resting dot to a full one.
    public static let row: [Dot] = [
        Dot(x: 0, y: 0, radius: 1.4, brightness: 0.5),
        Dot(x: 6.2, y: 0, radius: 1.85, brightness: 0.67),
        Dot(x: 12.4, y: 0, radius: 2.3, brightness: 0.84),
        Dot(x: 18.6, y: 0, radius: 2.75, brightness: 1),
    ]
    /// The aurora dot the row rises into: the wave's aurora dot at its fullest, a little further off than the pitch, as
    /// the wave leaves room before it.
    public static let accent = Dot(x: 26.4, y: 0, radius: 3.45, brightness: 1)

    /// The mark fitted into a box: the white dots and the aurora dot, in the box's coordinates.
    public struct Fitted: Equatable, Sendable {
        public var row: [Dot]
        public var accent: Dot
        /// Units to box points.
        public var scale: Double
    }

    /// The mark's ink in its units, with every dot `weight` times its radius.
    private static func ink(weight: Double) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let dots = row + [accent]
        return (dots.map { $0.x - $0.radius * weight }.min() ?? 0, dots.map { $0.y - $0.radius * weight }.min() ?? 0,
                dots.map { $0.x + $0.radius * weight }.max() ?? 0, dots.map { $0.y + $0.radius * weight }.max() ?? 0)
    }

    /// The mark as large as fits in a box at (`x`, `y`) of `width` by `height`, its ink centred there. `weight`
    /// enlarges every dot about its centre (1 is the mark's own): at the menu bar's size heavier dots keep the row
    /// from reading as dust. A box with no room gives a mark of no size at its centre.
    public static func fitted(x: Double, y: Double, width: Double, height: Double, weight: Double = 1) -> Fitted {
        let weight = weight.isFinite && weight > 0 ? weight : 1
        let ink = ink(weight: weight)
        let inkWidth = ink.maxX - ink.minX, inkHeight = ink.maxY - ink.minY
        let w = width.isFinite ? max(width, 0) : 0, h = height.isFinite ? max(height, 0) : 0
        let scale = max(0, min(w / inkWidth, h / inkHeight))
        let originX = x + w / 2 - (ink.minX + inkWidth / 2) * scale
        let originY = y + h / 2 - (ink.minY + inkHeight / 2) * scale
        func place(_ dot: Dot) -> Dot {
            Dot(x: originX + dot.x * scale, y: originY + dot.y * scale, radius: dot.radius * weight * scale,
                brightness: dot.brightness)
        }
        return Fitted(row: row.map(place), accent: place(accent), scale: scale)
    }
}
