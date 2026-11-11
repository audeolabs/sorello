import DesignCore
import ImageIO
import SwiftUI
import Testing
@testable import SorelloUI

/// ARCHITECTURE.md, section 8, "The mark": the iPhone app's icon is the same picture drawn to the edges, because iOS
/// cuts an icon's corners itself: the field fills the whole square, with no transparent pixel, and the mark lies
/// across its middle as it does on the Mac's. The App Store build has the plain one; a development build has the
/// stars. Each drawing test reads the rendered picture, as the icon files are written from it.
@MainActor
struct IPhoneIconTests {
    /// A picture as RGBA bytes in sRGB, row by row from the top left, however its file stores it.
    struct Picture {
        let width: Int, height: Int
        let bytes: [UInt8]

        init(_ png: Data) throws {
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
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
            try #require(drawn)
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        /// The pixel at (x, y), each channel from 0 to 1.
        subscript(x: Int, y: Int) -> (red: Double, green: Double, blue: Double, alpha: Double) {
            let index = (y * width + x) * 4
            return (Double(bytes[index]) / 255, Double(bytes[index + 1]) / 255, Double(bytes[index + 2]) / 255,
                    Double(bytes[index + 3]) / 255)
        }

        /// The largest difference between pixel (x, y) here and pixel (u, v) in `other`, in any channel.
        func difference(_ x: Int, _ y: Int, _ other: Picture, _ u: Int, _ v: Int) -> Double {
            let p = self[x, y], q = other[u, v]
            return max(abs(p.red - q.red), abs(p.green - q.green), abs(p.blue - q.blue), abs(p.alpha - q.alpha))
        }

        /// Whether pixel (x, y) is plainly orange.
        func isOrange(x: Int, y: Int) -> Bool {
            let pixel = self[x, y]
            return pixel.alpha > 0.9 && pixel.red > 0.6 && pixel.red - pixel.green > 0.2
                && pixel.green - pixel.blue > 0.2
        }
    }

    static func render(_ variant: AppIconView.Variant, pixels: Int = 1024) throws -> Picture {
        try Picture(try #require(AppIconView.png(pixels: pixels, variant: variant)))
    }

    /// Whether a PNG file has an alpha channel, whatever its pixels hold. The App Store refuses an icon that has one,
    /// even when every pixel is opaque.
    static func hasAlphaChannel(_ png: Data) throws -> Bool {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Both are 1024 pixel squares, the size the iPhone build compiles. No pixel of either is transparent, and neither
    /// is written with an alpha channel.
    @Test(arguments: [AppIconView.Variant.iPhone, .iPhoneDevelopment])
    func theIconIsAnOpaqueSquareOf1024Pixels(variant: AppIconView.Variant) throws {
        let png = try #require(AppIconView.png(variant: variant))
        let icon = try Picture(png)
        #expect(icon.width == 1024 && icon.height == 1024)
        let transparent = stride(from: 3, to: icon.bytes.count, by: 4).filter { icon.bytes[$0] < 255 }.count
        #expect(transparent == 0, "\(transparent) pixels are not opaque")
        let alpha = try Self.hasAlphaChannel(png)
        #expect(!alpha, "the icon is written with an alpha channel")
    }

    /// The field reaches every edge and every corner: the outermost pixels are the field's colour, as it is a little
    /// way in on the same row or column. The field's gradient runs from top to bottom, so along a row it is one
    /// colour.
    @Test(arguments: [AppIconView.Variant.iPhone, .iPhoneDevelopment])
    func theFieldFillsTheSquare(variant: AppIconView.Variant) throws {
        let icon = try Self.render(variant)
        let last = icon.width - 1, inset = 16
        var largest = 0.0, at = (x: 0, y: 0)
        func compare(_ x: Int, _ y: Int, with u: Int, _ v: Int) {
            let difference = icon.difference(x, y, icon, u, v)
            if difference > largest { (largest, at) = (difference, (x, y)) }
        }
        for along in 0 ... last {
            for depth in 0 ..< 8 {
                compare(depth, along, with: inset, along)
                compare(last - depth, along, with: last - inset, along)
                compare(along, depth, with: along, inset)
                compare(along, last - depth, with: along, last - inset)
            }
        }
        #expect(largest <= AppIconTests.renderNoise,
                "the edge differs from the field by \(largest * 255) / 255 at \(at)")
    }

    /// How far the Mac's field and the iPhone's may differ, in any channel, away from the Mac field's rim. They are
    /// the same picture rendered at two offsets, so the renderer's dithering differs by up to 3 steps of 255; the
    /// glow drawn a tenth too small differs by 10.
    static let sameField = 6.0 / 255

    /// Inside the Mac's field the iPhone's icon is the same picture: the Mac's icon at 1024 pixels and the iPhone's
    /// at 824, the Mac field's side, agree pixel for pixel but for the renderer's noise. So the mark, its glow, the
    /// field's gradient and the stars all keep their proportions to the field. Only the Mac field's edge, with its
    /// rim of light and its rounded corners, is left out.
    @Test(arguments: zip([AppIconView.Variant.plain, .nightly], [AppIconView.Variant.iPhone, .iPhoneDevelopment]))
    func theIconIsTheMacsFieldDrawnToTheEdges(mac: AppIconView.Variant, phone: AppIconView.Variant) throws {
        let macIcon = try Self.render(mac), side = Int(AppIconGeometry.fieldSide)
        let phoneIcon = try Self.render(phone, pixels: side)
        try #require(phoneIcon.width == side && phoneIcon.height == side)
        let offset = Int(AppIconGeometry.canvas - AppIconGeometry.fieldSide) / 2
        let inside = RoundedRectangle(cornerRadius: AppIconGeometry.fieldCornerRadius, style: .continuous)
            .path(in: CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 8, dy: 8))
        var largest = 0.0, at = (x: 0, y: 0), compared = 0
        for y in 0 ..< side {
            for x in 0 ..< side where inside.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                compared += 1
                let difference = phoneIcon.difference(x, y, macIcon, x + offset, y + offset)
                if difference > largest { (largest, at) = (difference, (x, y)) }
            }
        }
        #expect(compared > side * side * 9 / 10)
        #expect(largest <= Self.sameField, "differs from the Mac's by \(largest * 255) / 255 at \(at)")
    }

    /// The App Store build's icon has no orange; the development build's is the same picture with every star drawn,
    /// in orange, where the geometry puts it, and differs from it nowhere else.
    @Test func theDevelopmentIconIsThePlainOneWithStars() throws {
        let plain = try Self.render(.iPhone), development = try Self.render(.iPhoneDevelopment)
        let stars = AppIconGeometry.iPhone.stars
        for star in stars {
            #expect(development.isOrange(x: Int(star.x), y: Int(star.y)),
                    "no orange at the star at \(star.x), \(star.y)")
        }
        var largest = 0.0, at = (x: 0, y: 0), orange = 0
        for y in 0 ..< plain.height {
            for x in 0 ..< plain.width {
                if plain.isOrange(x: x, y: y) { orange += 1 }
                let nearAStar = stars.contains { star in
                    let dx = Double(x) + 0.5 - star.x, dy = Double(y) + 0.5 - star.y
                    return (dx * dx + dy * dy).squareRoot() <= star.radius + 3
                }
                guard !nearAStar else { continue }
                let difference = plain.difference(x, y, development, x, y)
                if difference > largest { (largest, at) = (difference, (x, y)) }
            }
        }
        #expect(orange == 0, "\(orange) orange pixels in the App Store build's icon")
        #expect(largest <= AppIconTests.renderNoise, "differs by \(largest * 255) / 255 at \(at), away from the stars")
    }
    /// iOS cuts the icon to a square with continuous corners, the shape SwiftUI draws as a continuous rounded
    /// rectangle. Every star lies well inside it, by the margin the Mac's stars keep from their field's edge under the
    /// same scaling, so none is clipped on the Home Screen.
    @Test func theStarsLieWellInsideTheShapeIOSCutsTheIconTo() {
        let canvas = AppIconGeometry.canvas
        let shape = RoundedRectangle(cornerRadius: AppIconGeometry.iOSCornerRadius, style: .continuous)
            .path(in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
        let margin = 48 * AppIconGeometry.iPhone.fieldSide / AppIconGeometry.mac.fieldSide
        for star in AppIconGeometry.iPhone.stars {
            let reach = star.radius + margin
            let outside = (0 ..< 720).map { Double($0) / 720 * 2 * .pi }.filter { angle in
                !shape.contains(CGPoint(x: star.x + reach * cos(angle), y: star.y + reach * sin(angle)))
            }
            #expect(outside.isEmpty, "\(star) is less than \(margin) units inside the shape iOS cuts the icon to")
        }
    }

    /// The snapshot tool shows both icons at full size, and as an iPhone shows them on a dark and a light background,
    /// for review.
    @Test func theSnapshotsShowTheIPhoneIcons() {
        let names = MarkSnapshots.scenes.map(\.name)
        for name in ["mark-iphone-icon", "mark-iphone-icon-development", "mark-iphone-icon-sizes-dark",
                     "mark-iphone-icon-sizes-light"] {
            #expect(names.contains(name), "no scene \(name)")
        }
    }

    /// `iOS/Resources` holds both icons as the snapshot tool writes them: the App Store build's file is the plain icon
    /// and the development build's the one with stars, each the same picture as a render now, but for the renderer's
    /// noise, and without an alpha channel.
    @Test(arguments: zip(["AppIcon-Source.png", "AppIcon-Dev-Source.png"],
                         [AppIconView.Variant.iPhone, .iPhoneDevelopment]))
    func theIPhoneAppHoldsTheIcons(file: String, variant: AppIconView.Variant) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("iOS/Resources").appendingPathComponent(file)
        let data = try Data(contentsOf: url)
        let held = try Picture(data), drawn = try Self.render(variant)
        try #require(held.width == 1024 && held.height == 1024, "\(file) is \(held.width) by \(held.height) pixels")
        let alpha = try Self.hasAlphaChannel(data)
        #expect(!alpha, "\(file) has an alpha channel")
        var largest = 0.0, at = (x: 0, y: 0)
        for y in 0 ..< held.height {
            for x in 0 ..< held.width {
                let difference = held.difference(x, y, drawn, x, y)
                if difference > largest { (largest, at) = (difference, (x, y)) }
            }
        }
        #expect(largest <= AppIconTests.renderNoise, "\(file) differs from the icon by \(largest * 255) / 255 at \(at)")
    }
}
