import DesignCore
import Foundation
import Testing

/// ARCHITECTURE.md, section 8, "The mark": the app icon's layout, and Sorello Nightly's stars on its field, around the
/// mark and clear of it and of the aurora dot's glow.
@Suite struct AppIconGeometryTests {
    typealias Icon = AppIconGeometry

    static func distance(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    /// How far a point lies inside the field's rounded square: negative outside it. The corners are taken as circular
    /// arcs of the field's corner radius.
    static func depthInField(x: Double, y: Double) -> Double {
        let low = (Icon.canvas - Icon.fieldSide) / 2, high = low + Icon.fieldSide, radius = Icon.fieldCornerRadius
        let cornerX = min(max(x, low + radius), high - radius), cornerY = min(max(y, low + radius), high - radius)
        if cornerX != x && cornerY != y {
            return radius - distance((x, y), (cornerX, cornerY))
        }
        return min(x - low, high - x, y - low, high - y)
    }

    /// The mark fills its box in the middle of the canvas, its ink centred there, with the aurora dot on the right.
    @Test func theMarkIsCentredOnTheCanvas() {
        let mark = Icon.mark
        let dots = mark.row + [mark.accent]
        let left = dots.map { $0.x - $0.radius }.min() ?? 0, right = dots.map { $0.x + $0.radius }.max() ?? 0
        #expect(abs((left + right) / 2 - Icon.canvas / 2) < 1e-9)
        #expect(abs(right - left - Icon.markWidth) < 1e-9)
        for dot in dots { #expect(abs(dot.y - Icon.canvas / 2) < 1e-9) }
        #expect(mark.accent.x > (mark.row.map(\.x).max() ?? .infinity))
    }

    /// A few stars, each small beside the mark's dots, and each fully shown.
    @Test func thereAreAFewSmallStars() {
        #expect((5 ... 9).contains(Icon.stars.count), "\(Icon.stars.count) stars")
        let smallestWhiteDot = Icon.mark.row.map(\.radius).min() ?? 0
        for star in Icon.stars {
            #expect(star.radius > 0 && star.radius <= 1.5 * smallestWhiteDot, "\(star)")
            #expect(star.brightness > 0.5 && star.brightness <= 1, "\(star)")
        }
        #expect(Icon.starWaist > 0 && Icon.starWaist < 0.5, "a star's sides must bow in")
    }

    /// Every star lies on the field, well inside its edge and its rounded corners.
    @Test func theStarsAreOnTheField() {
        for star in Icon.stars {
            let depth = Self.depthInField(x: star.x, y: star.y) - star.radius
            #expect(depth >= 48, "\(star) is \(depth) units from the field's edge")
        }
    }

    /// No star comes near a dot of the mark or into the aurora dot's glow.
    @Test func theStarsAreClearOfTheMarkAndItsGlow() {
        let mark = Icon.mark
        for star in Icon.stars {
            for dot in mark.row + [mark.accent] {
                let gap = Self.distance((star.x, star.y), (dot.x, dot.y)) - dot.radius - star.radius
                #expect(gap >= 64, "\(star) is \(gap) units from the dot at \(dot.x)")
            }
            let fromGlow = Self.distance((star.x, star.y), (mark.accent.x, mark.accent.y)) - Icon.glowRadius
                - star.radius
            #expect(fromGlow >= 32, "\(star) is \(fromGlow) units from the glow")
        }
    }

    /// The stars are scattered around the mark: some above its row and some below, on both sides of the middle, and
    /// none touching another.
    @Test func theStarsAreScatteredAroundTheMark() {
        let stars = Icon.stars, middle = Icon.canvas / 2
        #expect(stars.filter { $0.y < middle }.count >= 2)
        #expect(stars.filter { $0.y > middle }.count >= 2)
        #expect(stars.filter { $0.x < middle }.count >= 2)
        #expect(stars.filter { $0.x > middle }.count >= 2)
        for (index, star) in stars.enumerated() {
            for other in stars[(index + 1)...] {
                let gap = Self.distance((star.x, star.y), (other.x, other.y)) - star.radius - other.radius
                #expect(gap >= 48, "\(star) and \(other) are \(gap) units apart")
            }
        }
    }
}

/// ARCHITECTURE.md, section 8: the nightly's stars are orange, apart from ember's amber and coral's red, and stand out
/// on the icon's near-black field.
@Suite struct NightlyStarColourTests {
    /// The hue in degrees, 0 to 360.
    static func hue(_ colour: RGB) -> Double {
        let high = max(colour.red, colour.green, colour.blue), low = min(colour.red, colour.green, colour.blue)
        guard high > low else { return 0 }
        let span = high - low
        let sector: Double
        switch high {
        case colour.red: sector = ((colour.green - colour.blue) / span).truncatingRemainder(dividingBy: 6)
        case colour.green: sector = (colour.blue - colour.red) / span + 2
        default: sector = (colour.red - colour.green) / span + 4
        }
        return (sector * 60 + 360).truncatingRemainder(dividingBy: 360)
    }

    @Test func tangerineIsOrange() {
        let tangerine = Palette.tangerine
        let hue = Self.hue(tangerine)
        #expect((20 ... 35).contains(hue), "hue \(hue)")
        #expect(abs(hue - Self.hue(Palette.ember)) >= 8, "too near ember's amber")
        #expect(abs(hue - Self.hue(Palette.coral)) >= 8, "too near coral's red")
        let chroma = max(tangerine.red, tangerine.green, tangerine.blue)
            - min(tangerine.red, tangerine.green, tangerine.blue)
        #expect(chroma >= 0.7, "not saturated enough to read as orange when small")
        #expect(RGB.contrast(tangerine, AppIconGeometry.fieldBottom) >= 3)
        #expect(RGB.contrast(tangerine, AppIconGeometry.fieldTop) >= 3)
    }
}

/// ARCHITECTURE.md, section 8, "The mark": the iPhone app's icon is the same picture drawn to the edges, because iOS
/// cuts an icon's corners itself. It is the Mac icon's field, with everything on it, scaled about the canvas's middle
/// until the field's sides are the canvas's, with square corners; a development build's stars are the nightly's under
/// the same scaling.
@Suite struct IPhoneIconGeometryTests {
    typealias Icon = AppIconGeometry
    static let middle = Icon.canvas / 2
    /// How much larger the iPhone's icon draws everything than the Mac's.
    static let scale = Icon.iPhone.fieldSide / Icon.mac.fieldSide

    static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    /// The Mac's layout is the Mac icon's own values, so both icons are drawn from one description.
    @Test func theMacsLayoutIsTheMacIcon() {
        let mac = Icon.mac
        #expect(mac.fieldSide == Icon.fieldSide && mac.fieldCornerRadius == Icon.fieldCornerRadius)
        #expect(mac.markWidth == Icon.markWidth && mac.markHeight == Icon.markHeight)
        #expect(mac.glowRadius == Icon.glowRadius)
        #expect(mac.stars == Icon.stars)
        #expect(mac.mark == Icon.mark)
    }

    /// The field fills the whole square, with square corners: iOS cuts them.
    @Test func theFieldIsTheWholeCanvas() {
        #expect(Icon.iPhone.fieldSide == Icon.canvas)
        #expect(Icon.iPhone.fieldCornerRadius == 0)
    }

    /// The mark lies across the middle, every dot where the Mac's is, in proportion to the field, and so does the
    /// aurora dot's glow.
    @Test func theMarkIsTheMacsInProportionToTheField() throws {
        let mac = Icon.mac, phone = Icon.iPhone
        let macDots = mac.mark.row + [mac.mark.accent], dots = phone.mark.row + [phone.mark.accent]
        try #require(dots.count == macDots.count)
        let left = dots.map { $0.x - $0.radius }.min() ?? 0, right = dots.map { $0.x + $0.radius }.max() ?? 0
        #expect(Self.near((left + right) / 2, Self.middle), "the mark's ink is not centred across the canvas")
        for (dot, macDot) in zip(dots, macDots) {
            #expect(Self.near((dot.x - Self.middle) / phone.fieldSide, (macDot.x - Self.middle) / mac.fieldSide))
            #expect(Self.near((dot.y - Self.middle) / phone.fieldSide, (macDot.y - Self.middle) / mac.fieldSide))
            #expect(Self.near(dot.radius / phone.fieldSide, macDot.radius / mac.fieldSide))
            #expect(dot.brightness == macDot.brightness)
            #expect(Self.near(dot.y, Self.middle))
        }
        #expect(Self.near(phone.markWidth / phone.fieldSide, mac.markWidth / mac.fieldSide))
        #expect(Self.near(phone.markHeight / phone.fieldSide, mac.markHeight / mac.fieldSide))
        #expect(Self.near(phone.glowRadius / phone.fieldSide, mac.glowRadius / mac.fieldSide))
    }

    /// Each star is the nightly's star, in the same place relative to the mark and the same size beside it.
    @Test func eachStarIsTheNightlysStarDrawnToTheEdges() {
        let mac = Icon.mac, phone = Icon.iPhone
        #expect(phone.stars.count == mac.stars.count)
        for (star, macStar) in zip(phone.stars, mac.stars) {
            #expect(Self.near((star.x - Self.middle) / phone.fieldSide, (macStar.x - Self.middle) / mac.fieldSide),
                    "\(star) is not \(macStar) drawn to the edges")
            #expect(Self.near((star.y - Self.middle) / phone.fieldSide, (macStar.y - Self.middle) / mac.fieldSide),
                    "\(star) is not \(macStar) drawn to the edges")
            #expect(Self.near(star.radius / phone.fieldSide, macStar.radius / mac.fieldSide))
            #expect(star.brightness == macStar.brightness)
        }
    }

    /// No star comes near a dot of the mark or into the aurora dot's glow, by the Mac's margins under the same
    /// scaling.
    @Test func theStarsAreClearOfTheMarkAndItsGlow() {
        let phone = Icon.iPhone, mark = phone.mark
        for star in phone.stars {
            for dot in mark.row + [mark.accent] {
                let gap = AppIconGeometryTests.distance((star.x, star.y), (dot.x, dot.y)) - dot.radius - star.radius
                #expect(gap >= 64 * Self.scale, "\(star) is \(gap) units from the dot at \(dot.x)")
            }
            let fromGlow = AppIconGeometryTests.distance((star.x, star.y), (mark.accent.x, mark.accent.y))
                - phone.glowRadius - star.radius
            #expect(fromGlow >= 32 * Self.scale, "\(star) is \(fromGlow) units from the glow")
        }
    }

    /// The shape the stars are held inside, and the pictures cut the icon to, is iOS's: a square with continuous
    /// corners whose radius is about 22.4% of its side.
    @Test func iOSCutsTheCornersAtAbout22Percent() {
        #expect(abs(Icon.iOSCornerRadius / Icon.canvas - 0.224) < 0.002)
    }
}
