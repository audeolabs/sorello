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
