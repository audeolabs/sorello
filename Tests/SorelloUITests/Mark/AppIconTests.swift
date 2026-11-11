import AppKit
import DesignCore
import ImageIO
import Testing
@testable import SorelloUI

/// ARCHITECTURE.md, section 8, "The mark": Sorello Nightly's icon is the plain icon with a few small orange stars on
/// its field, always in the same places. Each test reads the rendered picture, as the icon file is built from it.
@MainActor
struct AppIconTests {
    static let pixels = 512
    /// How far one render of a picture may differ from another of the same picture, in any channel. SwiftUI's renderer
    /// dithers gradients and edges tile by tile, and while other renders run at the same time two renders in one
    /// process can differ by a step or two, and on the field's rim by as much as 7 steps of 255. Anything drawn in
    /// another place differs by far more.
    static let renderNoise = 16.0 / 255

    /// The largest difference between two pictures of one size, in any channel, and where it is, outside the pixels
    /// `skip` names.
    static func largestDifference(_ a: Pixels, _ b: Pixels,
                                  skip: (Int, Int) -> Bool = { _, _ in false }) -> (Double, (x: Int, y: Int)) {
        var largest = 0.0, at = (x: 0, y: 0)
        for y in 0 ..< min(a.height, b.height) {
            for x in 0 ..< min(a.width, b.width) where !skip(x, y) {
                let p = a[x, y], q = b[x, y]
                let difference = max(abs(p.red - q.red), abs(p.green - q.green), abs(p.blue - q.blue),
                                     abs(p.alpha - q.alpha))
                if difference > largest { (largest, at) = (difference, (x, y)) }
            }
        }
        return (largest, at)
    }

    /// The icon as RGBA pixels from 0 to 1, row by row from the top left.
    struct Pixels {
        let width: Int, height: Int
        let values: [Double]

        init(_ png: Data) throws {
            let bitmap = try #require(NSBitmapImageRep(data: png))
            try #require(bitmap.bitsPerSample == 8 && bitmap.samplesPerPixel == 4)
            width = bitmap.pixelsWide
            height = bitmap.pixelsHigh
            var values: [Double] = []
            values.reserveCapacity(width * height * 4)
            var pixel = [Int](repeating: 0, count: 4)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    bitmap.getPixel(&pixel, atX: x, y: y)
                    values += pixel.map { Double($0) / 255 }
                }
            }
            self.values = values
        }

        subscript(x: Int, y: Int) -> (red: Double, green: Double, blue: Double, alpha: Double) {
            let index = (y * width + x) * 4
            return (values[index], values[index + 1], values[index + 2], values[index + 3])
        }

        /// Whether a pixel is plainly orange: red well above green, and green well above blue.
        func isOrange(x: Int, y: Int) -> Bool {
            let pixel = self[x, y]
            return pixel.alpha > 0.9 && pixel.red > 0.6 && pixel.red - pixel.green > 0.2
                && pixel.green - pixel.blue > 0.2
        }
    }

    static func render(_ variant: AppIconView.Variant) throws -> Pixels {
        try Pixels(try #require(AppIconView.png(pixels: pixels, variant: variant)))
    }

    /// Whether pixel (x, y) is within `slack` pixels of a star, in a picture `pixels` wide.
    static func nearAStar(x: Int, y: Int, slack: Double) -> Bool {
        let scale = Double(pixels) / AppIconGeometry.canvas
        return AppIconGeometry.stars.contains { star in
            let dx = (Double(x) + 0.5) - star.x * scale, dy = (Double(y) + 0.5) - star.y * scale
            return (dx * dx + dy * dy).squareRoot() <= star.radius * scale + slack
        }
    }

    /// Every star is drawn, in orange, where the geometry puts it, and the picture differs from the plain icon nowhere
    /// else: the mark, its glow, the field and its edge are untouched.
    @Test func theNightlyIsThePlainIconWithStarsOnItsField() throws {
        let plain = try Self.render(.plain), nightly = try Self.render(.nightly)
        try #require(plain.width == Self.pixels && nightly.width == Self.pixels && nightly.height == Self.pixels)
        let scale = Double(Self.pixels) / AppIconGeometry.canvas
        for star in AppIconGeometry.stars {
            let x = Int(star.x * scale), y = Int(star.y * scale)
            #expect(nightly.isOrange(x: x, y: y), "no orange at the star at \(star.x), \(star.y)")
            #expect(!plain.isOrange(x: x, y: y))
        }
        // Away from the stars the two pictures may differ only by the renderer's noise.
        let (largest, at) = Self.largestDifference(plain, nightly) { Self.nearAStar(x: $0, y: $1, slack: 1.5) }
        #expect(largest <= Self.renderNoise, "differs by \(largest * 255) / 255 at \(at), away from the stars")
    }

    /// The plain icon, which release and development builds carry, has no orange in it at all.
    @Test func thePlainIconHasNoStars() throws {
        let plain = try Self.render(.plain)
        let orange = (0 ..< Self.pixels).flatMap { y in (0 ..< Self.pixels).filter { plain.isOrange(x: $0, y: y) } }
        #expect(orange.isEmpty)
    }

    /// The stars are always in the same places: two renders of either icon are the same picture, but for the
    /// renderer's noise. (The snapshot tool, run alone, gives the same bytes every time; that is checked on the Mac
    /// by comparing its pictures' hashes.)
    @Test(arguments: [AppIconView.Variant.plain, .nightly])
    func everyRenderIsTheSamePicture(variant: AppIconView.Variant) throws {
        let first = try Self.render(variant), second = try Self.render(variant)
        let (largest, at) = Self.largestDifference(first, second)
        #expect(largest <= Self.renderNoise, "two renders differ by \(largest * 255) / 255 at \(at)")
    }

    /// Every image in one of the repository's icon files, at its width in pixels, as RGBA bytes.
    static func icon(_ name: String) throws -> [(width: Int, bytes: [UInt8])] {
        let url = try #require(Resources.directory).appendingPathComponent(name)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "no \(name)")
        return try (0 ..< CGImageSourceGetCount(source)).map { index in
            let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let drawn = bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            try #require(drawn && width == height)
            return (width, bytes)
        }.sorted { $0.width < $1.width }
    }

    /// Whether any pixel of an RGBA picture is plainly orange.
    static func hasOrange(_ bytes: [UInt8]) -> Bool {
        stride(from: 0, to: bytes.count, by: 4).contains { index in
            let red = Int(bytes[index]), green = Int(bytes[index + 1]), blue = Int(bytes[index + 2])
            return bytes[index + 3] > 230 && red > 150 && red - green > 50 && green - blue > 50
        }
    }

    /// The icon files the build ships: the nightly's holds every size the plain one does, with stars from 64 pixels
    /// up, and is the plain icon at 32 pixels and under, where the stars would be only specks.
    @Test func theNightlyIconFileHasStarsWhereTheyCanBeSeen() throws {
        let plain = try Self.icon("AppIcon.icns"), nightly = try Self.icon("AppIcon-Nightly.icns")
        #expect(nightly.map(\.width) == plain.map(\.width))
        #expect(Set(nightly.map(\.width)) == [16, 32, 64, 128, 256, 512, 1024])
        for (ours, theirs) in zip(nightly, plain) where ours.width == theirs.width {
            if ours.width <= 32 {
                #expect(ours.bytes == theirs.bytes, "the nightly's \(ours.width) px image is not the plain icon's")
            } else {
                #expect(Self.hasOrange(ours.bytes), "no stars in the nightly's \(ours.width) px image")
                #expect(!Self.hasOrange(theirs.bytes), "orange in the plain \(theirs.width) px image")
            }
        }
    }

    /// The snapshot tool shows the nightly icon beside the plain one, for review.
    @Test func theSnapshotsShowTheNightlyIcon() {
        let names = MarkSnapshots.scenes.map(\.name)
        #expect(names.contains("mark-app-icon"))
        #expect(names.contains("mark-app-icon-nightly"))
    }
}
