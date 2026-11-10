import AppKit
import QuartzCore

// What the Accessibility drag card is made of, under its frost (ARCHITECTURE.md, section 6): Liquid Glass on
// macOS 26 and later, the system's blurred material before that. This is the one place the card asks which system it
// runs on, so nothing else in it needs an availability annotation.

extension PermissionPanel {
    /// The two materials the card's surface can be.
    enum CardMaterial: Sendable, Equatable {
        /// Liquid Glass (`NSGlassEffectView`), from macOS 26.
        case liquidGlass
        /// The system's blurred material (`NSVisualEffectView`), before macOS 26.
        case blurredMaterial
    }

    /// The material behind the card's frost and content, cut to the card's rounded shape. The flight and the docked
    /// panel each have one, made the same way, so the hand-off between them stays pixel for pixel on either material.
    @MainActor
    struct CardBackdrop {
        /// What this backdrop is made of.
        let material: CardMaterial
        /// The view that draws the material. The card's surface holds it directly, under the frost.
        let view: NSView
        /// Cuts `view` to a rounded rectangle of a size and corner radius.
        private let cut: (NSSize, CGFloat) -> Void

        /// Liquid Glass where the system has it, the blurred material otherwise. `forcesOlderSurface` makes the
        /// blurred material on any system, so a test and a picture can show what macOS 15 draws.
        init(forcesOlderSurface: Bool = false) {
            if !forcesOlderSurface, #available(macOS 26, *) {
                let glass = NSGlassEffectView()
                glass.style = .regular
                material = .liquidGlass
                view = glass
                cut = { _, radius in glass.cornerRadius = radius }
            } else {
                let blur = NSVisualEffectView()
                blur.material = .hudWindow
                // Behind the window, the material blurs System Settings under the card. Active whichever app is in
                // front: Sorello never is while the card is up, and an inactive material is drawn flat.
                blur.blendingMode = .behindWindow
                blur.state = .active
                material = .blurredMaterial
                view = blur
                cut = { size, radius in blur.maskImage = CardBackdrop.mask(size: size, radius: radius) }
            }
        }

        /// Fills a card of `size` and rounds the material's corners to `radius`, as the frost and content are rounded.
        func apply(size: NSSize, radius: CGFloat) {
            view.frame = NSRect(origin: .zero, size: size)
            cut(size, radius)
        }

        /// The blurred material's shape: opaque inside the card's rounded rectangle, clear outside it. It is drawn
        /// from a layer rounded as the surface's clip is, so the blur, the frost and the content share one outline.
        /// With behind-window blending the window server blurs only where this mask is opaque, which a layer's corner
        /// radius does not tell it.
        static func mask(size: NSSize, radius: CGFloat) -> NSImage {
            let shape = CALayer()
            shape.frame = CGRect(origin: .zero, size: size)
            shape.backgroundColor = NSColor.black.cgColor
            shape.cornerRadius = radius
            shape.cornerCurve = .continuous
            return NSImage(size: size, flipped: false) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                shape.render(in: context)
                return true
            }
        }
    }
}
