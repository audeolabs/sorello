import AppKit
import SwiftUI

/// The colours the Accessibility drag card draws its own chrome with. The app fills it from `Palette`
/// (ARCHITECTURE.md, section 8): white ink, the card colour for the app row, the hairline edge, the screen colour
/// behind the frosted glass, and aurora for the check mark once access is granted. MacPlatform does not depend on
/// DesignCore, so the colours are handed in.
public struct PermissionCardStyle: Sendable, Equatable {
    /// An sRGB colour, components from 0 to 1.
    public struct Colour: Sendable, Equatable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
        var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    }

    /// Text, the arrow and the back button.
    public var ink: Colour
    /// The instruction's text is `ink` at this opacity.
    public var secondaryInkAlpha: Double
    /// Tints the glass behind the content, so rows of the window behind do not read through.
    public var surface: Colour
    /// The draggable app row.
    public var row: Colour
    /// The app row's hairline edge.
    public var edge: Colour
    /// The check mark shown once access is granted.
    public var done: Colour

    public init(ink: Colour, secondaryInkAlpha: Double, surface: Colour, row: Colour, edge: Colour, done: Colour) {
        self.ink = ink
        self.secondaryInkAlpha = secondaryInkAlpha
        self.surface = surface
        self.row = row
        self.edge = edge
        self.done = done
    }
}
