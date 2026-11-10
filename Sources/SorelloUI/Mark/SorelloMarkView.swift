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
            let mark = SorelloMark.fitted(x: 0, y: 0, width: Double(size.width), height: Double(size.height),
                                          weight: weight)
            for dot in mark.row {
                context.fill(Path(ellipseIn: Self.box(dot)), with: .color(Color(Palette.ink).opacity(dot.brightness)))
            }
            context.fill(Path(ellipseIn: Self.box(mark.accent)), with: .color(Color(Palette.aurora)))
        }
        .accessibilityHidden(true)
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
/// spacing suit it. Drawn in any square; the snapshot tool renders it at 1024 px.
public struct AppIconView: View {
    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            let unit = min(geometry.size.width, geometry.size.height) / 1024
            ZStack {
                RoundedRectangle(cornerRadius: 185.4 * unit, style: .continuous)
                    .fill(LinearGradient(colors: [Color(RGB(hex: 0x16211F)), Color(Palette.screen)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(
                        // A faint rim of light at the top edge, as a polished black surface catches it.
                        RoundedRectangle(cornerRadius: 185.4 * unit, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02)],
                                                         startPoint: .top, endPoint: .center),
                                          lineWidth: 3 * unit)
                    )
                    .frame(width: 824 * unit, height: 824 * unit)
                    .shadow(color: .black.opacity(0.35), radius: 14 * unit, y: 10 * unit)
                // The aurora dot's glow, under the mark.
                Circle()
                    .fill(RadialGradient(colors: [Color(Palette.aurora).opacity(0.32), .clear], center: .center,
                                         startRadius: 0, endRadius: 120 * unit))
                    .frame(width: 240 * unit, height: 240 * unit)
                    .offset(x: Self.accentOffset * unit)
                SorelloMarkView()
                    .frame(width: 560 * unit, height: 160 * unit)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
    }

    /// Where the aurora dot's centre falls, in icon units from the middle, when the mark is 560 units wide.
    private static var accentOffset: CGFloat {
        let mark = SorelloMark.fitted(x: -280, y: -80, width: 560, height: 160)
        return CGFloat(mark.accent.x)
    }
}

public extension AppIconView {
    /// The icon as a PNG `pixels` square, its corners transparent, for building `Resources/AppIcon.icns`.
    static func png(pixels: Int = 1024) -> Data? {
        let renderer = ImageRenderer(content: AppIconView().frame(width: CGFloat(pixels), height: CGFloat(pixels)))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
