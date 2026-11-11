import Foundation

/// The app icon's layout (ARCHITECTURE.md, section 8, "The mark"), in the units of its 1024-unit canvas with the origin
/// at the top left: a near-black rounded square on the macOS icon grid, the mark across its middle with a glow around
/// the aurora dot, and, on Sorello Nightly's icon only, a few small orange stars on the field around them. The iPhone
/// app's icon is the same picture drawn to the edges (`iPhone`). The icon view draws from here, so the tests can hold
/// the stars clear of everything else.
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

public extension AppIconGeometry {
    /// One icon's layout on the canvas: a square field in the canvas's middle, the box the mark fills, centred there,
    /// the reach of the aurora dot's glow, and the stars of a build that has them.
    struct Layout: Equatable, Sendable {
        /// The field's side.
        public var fieldSide: Double
        /// The radius of the field's continuous corners; 0 for square ones.
        public var fieldCornerRadius: Double
        public var markWidth: Double
        public var markHeight: Double
        public var glowRadius: Double
        public var stars: [Star]

        public init(fieldSide: Double, fieldCornerRadius: Double, markWidth: Double, markHeight: Double,
                    glowRadius: Double, stars: [Star]) {
            self.fieldSide = fieldSide
            self.fieldCornerRadius = fieldCornerRadius
            self.markWidth = markWidth
            self.markHeight = markHeight
            self.glowRadius = glowRadius
            self.stars = stars
        }

        /// The mark where this icon draws it: as large as fits its box, its ink centred on the canvas.
        public var mark: SorelloMark.Fitted {
            let canvas = AppIconGeometry.canvas
            return SorelloMark.fitted(x: (canvas - markWidth) / 2, y: (canvas - markHeight) / 2, width: markWidth,
                                      height: markHeight)
        }
    }

    /// The Mac's icon: the values above.
    static var mac: Layout {
        Layout(fieldSide: fieldSide, fieldCornerRadius: fieldCornerRadius, markWidth: markWidth, markHeight: markHeight,
               glowRadius: glowRadius, stars: stars)
    }

    /// The iPhone app's icon: the Mac's field with everything on it, scaled about the canvas's middle until the
    /// field's sides are the canvas's, with square corners, because iOS cuts an icon's corners itself and the App
    /// Store refuses an icon with a transparent pixel. Its stars, which only a development build's icon has, are the
    /// nightly's under the same scaling. Nothing else about the picture changes.
    static var iPhone: Layout {
        let scale = canvas / fieldSide, middle = canvas / 2
        return Layout(fieldSide: canvas, fieldCornerRadius: 0, markWidth: markWidth * scale,
                      markHeight: markHeight * scale, glowRadius: glowRadius * scale,
                      stars: stars.map { star in
                          Star(x: middle + (star.x - middle) * scale, y: middle + (star.y - middle) * scale,
                               radius: star.radius * scale, brightness: star.brightness)
                      })
    }

    /// The shape iOS cuts an app icon to is a square with continuous corners of this radius, about 22.4% of its side.
    /// Sorello does not draw it: the pictures that show the iPhone's icon as an iPhone does are cut to it, and the
    /// tests hold the stars well inside it.
    static let iOSCornerRadius = 0.224 * canvas
}
