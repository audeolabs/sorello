import Foundation

/// The app icon's layout (ARCHITECTURE.md, section 8, "The mark"), in the units of its 1024-unit canvas with the origin
/// at the top left: a near-black rounded square on the macOS icon grid, the mark across its middle with a glow around
/// the aurora dot, and, on Sorello Nightly's icon only, a few small orange stars on the field around them. The icon
/// view draws from here, so the tests can hold the stars clear of everything else.
public enum AppIconGeometry {
    /// The canvas's side. The system's icon grid is laid out on a canvas this size.
    public static let canvas = 1024.0
    /// The field's side: a rounded square in the canvas's middle, the grid's size for a Mac app icon.
    public static let fieldSide = 824.0
    /// The radius of the field's continuous corners.
    public static let fieldCornerRadius = 185.4
    /// The field's colour at its top edge; it darkens to `fieldBottom` at its bottom edge.
    public static let fieldTop = RGB(hex: 0x16211F)
    /// The field's colour at its bottom edge: the window background.
    public static let fieldBottom = Palette.screen
    /// The box the mark fills, centred in the canvas. The mark is wider than this box is tall, so its ink spans the
    /// width and is centred in the height.
    public static let markWidth = 560.0
    public static let markHeight = 160.0
    /// How far the aurora dot's glow reaches from that dot's centre.
    public static let glowRadius = 120.0

    /// The mark where the icon draws it.
    public static var mark: SorelloMark.Fitted {
        SorelloMark.fitted(x: (canvas - markWidth) / 2, y: (canvas - markHeight) / 2, width: markWidth,
                           height: markHeight)
    }

    /// One of the nightly's stars: four points around its centre, joined by sides that bow in towards it.
    public struct Star: Equatable, Sendable {
        /// The centre.
        public var x: Double
        public var y: Double
        /// From the centre to each of its points, which reach straight up, down, left and right.
        public var radius: Double
        /// Its opacity, 0 to 1: the nearer stars brighter, the further ones a little dimmer.
        public var brightness: Double

        public init(x: Double, y: Double, radius: Double, brightness: Double) {
            self.x = x
            self.y = y
            self.radius = radius
            self.brightness = brightness
        }
    }

    /// How far a star's sides bow in: each side is a quadratic curve from one point to the next whose control point
    /// lies on the diagonal between them, this fraction of the radius out from the centre along each axis. Below a
    /// half the sides are concave, so the star has four slender points rather than reading as a dot or a diamond.
    public static let starWaist = 0.2

    /// Sorello Nightly's stars, in `tangerine`: a quiet scatter on the field above and below the mark, in fixed places
    /// so every render is the same picture. The larger ones are big enough to read as stars in the Dock at 128 pixels.
    public static let stars: [Star] = [
        Star(x: 296, y: 262, radius: 32, brightness: 1),
        Star(x: 530, y: 206, radius: 18, brightness: 0.85),
        Star(x: 664, y: 322, radius: 23, brightness: 1),
        Star(x: 812, y: 238, radius: 15, brightness: 0.85),
        Star(x: 196, y: 652, radius: 15, brightness: 0.85),
        Star(x: 380, y: 722, radius: 23, brightness: 1),
        Star(x: 712, y: 770, radius: 30, brightness: 1),
        Star(x: 540, y: 852, radius: 14, brightness: 0.85),
    ]
}
