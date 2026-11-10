import AppKit
import DesignCore
import SwiftUI

/// The windows' surfaces and inks as plain colours, so their contrast can be checked without drawing anything. The
/// app is always dark: white ink, near-black surfaces, and the palette's accents only on small marks of state
/// (ARCHITECTURE.md, section 8).
nonisolated public enum ThemeColors {
    /// A row under the pointer is lifted by white at this opacity.
    public static let hoverAlpha = 0.05
    /// A selected row (the sidebar's current section, a preset that is chosen) is white at this opacity.
    public static let selectionAlpha = 0.11
    /// Key caps, chips and the tracks of switches and presets are white at this opacity.
    public static let controlFillAlpha = 0.08
    /// The hairline between rows.
    public static let separatorAlpha = 0.08

    /// Every surface text is drawn on, composited as the screen shows it.
    public static var textSurfaces: [RGB] {
        let card = Palette.card, screen = Palette.screen
        return [
            screen,
            card,
            Palette.pill,
            Palette.ink.blended(alpha: hoverAlpha, over: card),
            Palette.ink.blended(alpha: hoverAlpha, over: screen),
            Palette.ink.blended(alpha: selectionAlpha, over: screen),
            Palette.ink.blended(alpha: selectionAlpha, over: card),
            Palette.ink.blended(alpha: controlFillAlpha, over: card),
            Palette.ink.blended(alpha: controlFillAlpha + hoverAlpha, over: card),
        ]
    }

    /// Secondary text as it lands on `surface`.
    public static func secondaryInk(over surface: RGB) -> RGB {
        Palette.ink.blended(alpha: Palette.secondaryInkAlpha, over: surface)
    }
}

/// Sorello's colours for SwiftUI.
public enum Theme {
    /// Window background, behind cards.
    public static let screen = Color(Palette.screen)
    /// Rows and cards.
    public static let card = Color(Palette.card)
    /// The island's near-black: primary buttons, fields and round controls.
    public static let pill = Color(Palette.pill)
    /// The hairline around the island's surfaces.
    public static let edge = Color(Palette.edge)

    /// Primary text and glyphs.
    public static let ink = Color.white
    /// Details, captions and quiet actions.
    public static let secondaryInk = Color.white.opacity(Palette.secondaryInkAlpha)
    /// A state's dot without an accent.
    public static let neutralDot = Color.white.opacity(Palette.neutralDotAlpha)

    /// Ready, live, done.
    public static let aurora = Color(Palette.aurora)
    /// Preparing, and the wait's shimmer.
    public static let glacier = Color(Palette.glacier)
    /// An error's symbol; never a dot.
    public static let ember = Color(Palette.ember)
    /// Destructive actions only.
    public static let coral = Color(Palette.coral)
    /// A switch that is on.
    public static let toggle = Color(Palette.toggle)

    /// The lift under the pointer.
    public static let hover = Color.white.opacity(ThemeColors.hoverAlpha)
    /// The chosen row or segment.
    public static let selection = Color.white.opacity(ThemeColors.selectionAlpha)
    /// The fill of key caps, chips and tracks.
    public static let controlFill = Color.white.opacity(ThemeColors.controlFillAlpha)
    /// The hairline between rows.
    public static let separator = Color.white.opacity(ThemeColors.separatorAlpha)
}

/// Spacing and sizes, on a 4 pt grid, at the Mac's metrics rather than the iPhone's.
public enum Metrics {
    /// Inside a card, from its edge to the content.
    public static let rowInset: CGFloat = 14
    /// Above and below a row's content.
    public static let rowPadding: CGFloat = 10
    /// The smallest a row is, so rows with and without detail line up.
    public static let rowMinHeight: CGFloat = 44
    /// The width a row's glyph is centred in.
    public static let glyphWidth: CGFloat = 20
    /// Between a row's glyph and its words.
    public static let glyphGap: CGFloat = 12
    /// Where a row's words start when it has a glyph; the hairlines between such rows start here too.
    public static let wordsInset: CGFloat = rowInset + glyphWidth + glyphGap
    /// A card's corner radius.
    public static let cardRadius: CGFloat = 12
    /// Between a group's title and its card, and between stacked controls.
    public static let tight: CGFloat = 8
    /// Between cards.
    public static let groupGap: CGFloat = 22
    /// Around a window's content column.
    public static let pagePadding: CGFloat = 28
    /// The widest a content column grows, so lines stay readable in a wide window.
    public static let contentMaxWidth: CGFloat = 620
    /// The room a transparent title bar's window controls need above the content.
    public static let titleBarClearance: CGFloat = 40
    /// The main window's sidebar.
    public static let sidebarWidth: CGFloat = 196
    /// A text field's height.
    public static let fieldHeight: CGFloat = 28
    /// A text field's corner radius.
    public static let fieldRadius: CGFloat = 7
}

/// Display text (ARCHITECTURE.md, section 8): window and screen titles, setup's headlines and the app's name. It is
/// set as the Audeo Labs site sets its headings, in Urbanist Medium tracked in by 0.015 em, so a size is all a call
/// site chooses; `View.displayType(_:)` sets the face and the tracking together.
public struct DisplayType: Equatable {
    /// The size, in points.
    public var size: CGFloat

    /// Display text at `size` points.
    public init(size: CGFloat) {
        self.size = size
    }

    /// A screen's title, and a window's.
    public static let screenTitle = DisplayType(size: 30)
    /// The title of a setup step.
    public static let stepTitle = DisplayType(size: 32)

    /// How far apart display text's letters are moved, as a fraction of its size: in by 0.015 em.
    public static let trackingPerEm: CGFloat = -0.015

    /// The tracking at this size, in points.
    public var tracking: CGFloat { Self.trackingPerEm * size }

    /// The face at this size: Urbanist Medium once `Resources.registerFonts()` has run, and the system face at the
    /// same weight without the font file.
    public var face: NSFont {
        NSFont(name: Resources.displayFontName, size: size) ?? .systemFont(ofSize: size, weight: .medium)
    }
}

public extension View {
    /// Sets the text in this view as display text of `type`: its face, its size and its tracking at once, so display
    /// text is never drawn without its tracking.
    func displayType(_ type: DisplayType) -> some View {
        font(Font(type.face as CTFont)).tracking(type.tracking)
    }
}

/// Sorello's text styles in the system face.
public extension Font {
    /// A group's title above its card.
    static var groupTitle: Font { .system(size: 12, weight: .semibold) }
    /// A row's title.
    static var rowTitle: Font { .system(size: 13) }
    /// A row's second line.
    static var rowDetail: Font { .system(size: 11.5) }
}
