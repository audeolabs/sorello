import AppKit
import DesignCore
import SwiftUI

/// One picture the snapshot tool renders (ARCHITECTURE.md, section 11): a view in a fixed state at a fixed size.
/// Anything visible is reviewed in these images, so a scene must not depend on the clock, the screen or the user's
/// settings.
public struct SnapshotScene {
    /// The file name, without extension: lowercase words joined by hyphens, most general first
    /// ("pill-island-listening").
    public let name: String
    public let size: CGSize
    public let background: RGB
    public let make: () -> NSView

    public init(name: String, size: CGSize, background: RGB = Palette.screen, make: @escaping () -> NSView) {
        self.name = name
        self.size = size
        self.background = background
        self.make = make
    }

    public init(name: String, size: CGSize, background: RGB = Palette.screen, @ViewBuilder view: @escaping () -> some View) {
        self.init(name: name, size: size, background: background) {
            NSHostingView(rootView: view().frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        }
    }
}

/// Every scene, in the order the tool writes them.
public enum SnapshotCatalog {
    public static var all: [SnapshotScene] {
        [SnapshotRenderer.selfCheck] + PillSnapshots.scenes + ScreenSnapshots.scenes
    }
}

public enum SnapshotRenderer {
    /// Renders `scene` off screen and returns PNG data at `scale` pixels per point.
    public static func png(of scene: SnapshotScene, scale: CGFloat = 2) -> Data? {
        let frame = NSRect(origin: .zero, size: scene.size)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: scene.background.red, green: scene.background.green,
                                         blue: scene.background.blue, alpha: 1)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))

        let container = NSView(frame: frame)
        container.wantsLayer = true
        let view = scene.make()
        view.frame = frame
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()

        let width = Int((scene.size.width * scale).rounded()), height = Int((scene.size.height * scale).rounded())
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        bitmap.size = scene.size

        // The background first, then the layer tree: Core Animation layers and SwiftUI content both draw this way,
        // without the window ever being on screen.
        let graphics = context.cgContext
        graphics.setFillColor(window.backgroundColor.cgColor)
        graphics.fill(CGRect(x: 0, y: 0, width: width, height: height))
        graphics.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        container.cacheDisplay(in: container.bounds, to: bitmap)
        NSGraphicsContext.restoreGraphicsState()
        window.close()
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Proves the renderer itself: display text in the display font, a SwiftUI shape and a Core Animation layer.
    /// If this picture is blank or missing one of the three, no other picture can be trusted.
    static var selfCheck: SnapshotScene {
        SnapshotScene(name: "harness-self-check", size: CGSize(width: 360, height: 120)) {
            HStack(spacing: 16) {
                Text("Sorello")
                    .displayType(DisplayType(size: 34))
                    .foregroundStyle(.white)
                Capsule().fill(Color(Palette.pill)).overlay(Capsule().strokeBorder(Color(Palette.edge), lineWidth: 0.5))
                    .frame(width: 96, height: 32)
                LayerDot().frame(width: 24, height: 24)
            }
        }
    }
}

/// A Core Animation disc in aurora, as the pill's dots are drawn.
private struct LayerDot: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let dot = CALayer()
        dot.backgroundColor = NSColor(Palette.aurora).cgColor
        dot.frame = CGRect(x: 4, y: 4, width: 16, height: 16)
        dot.cornerRadius = 8
        view.layer?.addSublayer(dot)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

public extension Color {
    init(_ rgb: RGB) { self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1) }
}

public extension NSColor {
    convenience init(_ rgb: RGB, alpha: CGFloat = 1) {
        self.init(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
    }
}
