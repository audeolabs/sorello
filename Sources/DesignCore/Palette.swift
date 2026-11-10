import Foundation

/// A colour as sRGB components from 0 to 1, so contrast can be computed and tested without a UI framework.
public struct RGB: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `0x6DFFA8` style.
    public init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1 to 21.
    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (high, low) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (high + 0.05) / (low + 0.05)
    }

    /// This colour at `alpha` over `backdrop`, as the screen composites it.
    public func blended(alpha: Double, over backdrop: RGB) -> RGB {
        func mix(_ a: Double, _ b: Double) -> Double { a * alpha + b * (1 - alpha) }
        return RGB(mix(red, backdrop.red), mix(green, backdrop.green), mix(blue, backdrop.blue))
    }
}

/// Sorello's colours (ARCHITECTURE.md, section 8). The app is always dark and its controls are monochrome; the
/// three accents mark only small things that show a state.
public enum Palette {
    /// The mark's dot: ready, live, done.
    public static let aurora = RGB(hex: 0x6DFFA8)
    /// The wait's shimmer, and preparing.
    public static let glacier = RGB(hex: 0x67E8F9)
    /// An error's symbol. Never a dot.
    public static let ember = RGB(hex: 0xF5C66B)
    /// Destructive actions only.
    public static let coral = RGB(hex: 0xFF7D5E)

    /// Window background.
    public static let screen = RGB(hex: 0x05080A)
    /// Rows and cards on the screen.
    public static let card = RGB(hex: 0x0F1A1C)
    /// The pill and primary buttons.
    public static let pill = RGB(hex: 0x09090A)
    /// The hairline that sets the pill off from a dark backdrop.
    public static let edge = RGB(hex: 0x6E6E70)
    /// The pill's body where it must merge with a camera housing.
    public static let housing = RGB(0, 0, 0)
    public static let ink = RGB(1, 1, 1)
    /// A switch that is on: aurora a shade deeper, so the white knob stays crisp.
    public static let toggle = RGB(hex: 0x3FD17A)

    /// Secondary text is `ink` at this opacity.
    public static let secondaryInkAlpha = 0.6
    /// A state's dot without an accent (not prepared yet, cancelled) is `ink` at this opacity.
    public static let neutralDotAlpha = 0.4
    /// The shimmer's cool white: glacier at this opacity over white.
    public static let shimmer = glacier.blended(alpha: 0.55, over: ink)

    /// The pill's edge width in points: a hairline, a full point with Increase Contrast.
    public static func edgeWidth(highContrast: Bool) -> Double { highContrast ? 1 : 0.5 }
}
