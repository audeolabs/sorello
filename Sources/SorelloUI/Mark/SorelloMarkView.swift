import AppKit
import DesignCore
import SwiftUI

/// The Sorello mark as a view (ARCHITECTURE.md, section 8, "The mark"): the wave coming to rest, white dots rising
/// into the aurora dot. It fills its frame along one side, centred.
public struct SorelloMarkView: View {
    /// Enlarges every dot about its centre; small marks read better a little heavier.
    public var weight: Double

    public init(weight: Double = 1) {
        self.weight = weight
    }

    public var body: some View {
        Canvas { context, size in
            Self.draw(SorelloMark.fitted(x: 0, y: 0, width: Double(size.width), height: Double(size.height),
                                         weight: weight), in: context)
        }
        .accessibilityHidden(true)
    }

    /// Draws `mark`'s dots where it places them: the white dots at their brightness, then the aurora dot.
    static func draw(_ mark: SorelloMark.Fitted, in context: GraphicsContext) {
        for dot in mark.row {
            context.fill(Path(ellipseIn: box(dot)), with: .color(Color(Palette.ink).opacity(dot.brightness)))
        }
        context.fill(Path(ellipseIn: box(mark.accent)), with: .color(Color(Palette.aurora)))
    }

    static func box(_ dot: SorelloMark.Dot) -> CGRect {
        CGRect(x: dot.x - dot.radius, y: dot.y - dot.radius, width: 2 * dot.radius, height: 2 * dot.radius)
    }
}

/// The menu-bar icon and the app icon, both drawn from the mark.
public enum SorelloMarkImages {
    /// The menu bar's icon: the mark's row as a template image, which the system tints for a light or a dark bar.
    /// The white dots keep their rising brightness as opacity; the aurora dot is solid.
    public static func menuBarIcon() -> NSImage {
        let size = CGSize(width: 26, height: 16)
        let image = NSImage(size: size, flipped: true) { rect in
            let mark = SorelloMark.fitted(x: Double(rect.minX) + 1, y: Double(rect.minY), width: Double(rect.width) - 2,
                                          height: Double(rect.height), weight: 1.12)
            for dot in mark.row {
                NSColor(white: 0, alpha: 0.35 + 0.65 * dot.brightness).setFill()
                NSBezierPath(ovalIn: SorelloMarkView.box(dot)).fill()
            }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: SorelloMarkView.box(mark.accent)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        return image
    }
}

/// The app icon (ARCHITECTURE.md, section 8, "The mark"): the mark on a near-black field, laid out on the macOS icon
/// grid (an 824-unit rounded square in a 1024-unit canvas, with the grid's drop shadow), so the system's mask and
/// spacing suit it. Sorello Nightly's icon adds a few small orange stars to the field. The iPhone app's icon is the
/// same picture drawn to the edges, with square corners, because iOS cuts an icon's corners itself; its development
/// build's has the stars. Drawn in any square; the snapshot tool renders it at 1024 px. `AppIconGeometry` holds the
/// layout.
public struct AppIconView: View {
    /// Which build's icon this is.
    public enum Variant: Sendable {
        /// Sorello's own icon, which the Mac app's release and development builds carry.
        case plain
        /// Sorello Nightly's: the plain icon with stars on its field, so a nightly is told from a release at a glance.
        case nightly
        /// The iPhone app's, which its App Store build carries: the plain icon drawn to the edges.
        case iPhone
        /// The iPhone app's development build's, which can be on one iPhone beside the App Store build: the iPhone's
        /// icon with the nightly's stars.
        case iPhoneDevelopment

        /// Whether this is an iPhone's icon, whose field fills the square.
        var fillsTheSquare: Bool { self == .iPhone || self == .iPhoneDevelopment }
        var hasStars: Bool { self == .nightly || self == .iPhoneDevelopment }
        var layout: AppIconGeometry.Layout { fillsTheSquare ? AppIconGeometry.iPhone : AppIconGeometry.mac }
    }

    private let variant: Variant

    public init(_ variant: Variant = .plain) {
        self.variant = variant
    }

    public var body: some View {
        GeometryReader { geometry in
            let unit = min(geometry.size.width, geometry.size.height) / AppIconGeometry.canvas
            let layout = variant.layout
            let field = LinearGradient(colors: [Color(AppIconGeometry.fieldTop), Color(AppIconGeometry.fieldBottom)],
                                       startPoint: .top, endPoint: .bottom)
            ZStack {
                if variant.fillsTheSquare {
                    // No rim and no shadow. The Mac's rim of light follows its rounded corners; on this square the
                    // corners iOS cuts would leave it only along the straight middle of each edge, a line that stops
                    // short. The shadow would fall outside the square.
                    Rectangle()
                        .fill(field)
                        .frame(width: layout.fieldSide * unit, height: layout.fieldSide * unit)
                } else {
                    RoundedRectangle(cornerRadius: layout.fieldCornerRadius * unit, style: .continuous)
                        .fill(field)
                        .overlay(
                            // A faint rim of light at the top edge, as a polished black surface catches it.
                            RoundedRectangle(cornerRadius: layout.fieldCornerRadius * unit, style: .continuous)
                                .strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02)],
                                                             startPoint: .top, endPoint: .center),
                                              lineWidth: 3 * unit)
                        )
                        .frame(width: layout.fieldSide * unit, height: layout.fieldSide * unit)
                        .shadow(color: .black.opacity(0.35), radius: 14 * unit, y: 10 * unit)
                }
                if variant.hasStars {
                    Canvas { context, size in
                        Self.draw(layout.stars, in: context, size: size, unit: unit)
                    }
                }
                // The aurora dot's glow, under the mark.
                Circle()
                    .fill(RadialGradient(colors: [Color(Palette.aurora).opacity(0.32), .clear], center: .center,
                                         startRadius: 0, endRadius: layout.glowRadius * unit))
                    .frame(width: 2 * layout.glowRadius * unit, height: 2 * layout.glowRadius * unit)
                    .offset(x: Self.accentOffset(layout) * unit)
                SorelloMarkView()
                    .frame(width: layout.markWidth * unit, height: layout.markHeight * unit)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
    }

    /// Where the aurora dot's centre falls, in icon units from the middle, when the mark fills its box.
    private static func accentOffset(_ layout: AppIconGeometry.Layout) -> CGFloat {
        let mark = SorelloMark.fitted(x: -layout.markWidth / 2, y: -layout.markHeight / 2, width: layout.markWidth,
                                      height: layout.markHeight)
        return CGFloat(mark.accent.x)
    }

    /// Draws `stars` in `tangerine`, each at its brightness, on a canvas of `size` whose middle is the icon's middle
    /// and whose icon unit is `unit` points.
    private static func draw(_ stars: [AppIconGeometry.Star], in context: GraphicsContext, size: CGSize,
                             unit: CGFloat) {
        let originX = size.width / 2 - AppIconGeometry.canvas / 2 * unit
        let originY = size.height / 2 - AppIconGeometry.canvas / 2 * unit
        for star in stars {
            func point(_ dx: Double, _ dy: Double) -> CGPoint {
                CGPoint(x: originX + (star.x + dx * star.radius) * unit,
                        y: originY + (star.y + dy * star.radius) * unit)
            }
            // The four points, clockwise from the top, each joined to the next by a side that bows in.
            let tips: [(Double, Double)] = [(0, -1), (1, 0), (0, 1), (-1, 0)]
            var path = Path()
            path.move(to: point(tips[0].0, tips[0].1))
            for (from, to) in zip(tips, tips.dropFirst() + tips.prefix(1)) {
                let waist = AppIconGeometry.starWaist
                path.addQuadCurve(to: point(to.0, to.1),
                                  control: point((from.0 + to.0) * waist, (from.1 + to.1) * waist))
            }
            path.closeSubpath()
            context.fill(path, with: .color(Color(Palette.tangerine).opacity(star.brightness)))
        }
    }
}

public extension AppIconView {
    /// The icon as a PNG `pixels` square: for the Mac, its corners transparent, for building `Resources/AppIcon.icns`
    /// (the plain icon) or `Resources/AppIcon-Nightly.icns` (the nightly's); for the iPhone, opaque to every edge with
    /// no alpha channel, as `iOS/Resources/AppIcon-Source.png` (the App Store build's) and
    /// `iOS/Resources/AppIcon-Dev-Source.png` (the development build's).
    static func png(pixels: Int = 1024, variant: Variant = .plain) -> Data? {
        let renderer = ImageRenderer(content: AppIconView(variant)
            .frame(width: CGFloat(pixels), height: CGFloat(pixels)))
        renderer.scale = 1
        renderer.isOpaque = variant.fillsTheSquare
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
