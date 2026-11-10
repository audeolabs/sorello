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

    public static let hover = Color.white.opacity(ThemeColors.hoverAlpha)
    public static let selection = Color.white.opacity(ThemeColors.selectionAlpha)
    public static let controlFill = Color.white.opacity(ThemeColors.controlFillAlpha)
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
    public static let sidebarWidth: CGFloat = 196
    public static let fieldHeight: CGFloat = 28
    public static let fieldRadius: CGFloat = 7
}

public extension Font {
    /// Geist Serif, the display face: window titles and headlines only. It has one weight and is never bolded.
    /// Without the font the system face stands in.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        Resources.hasDisplayFont ? .custom(Resources.displayFontName, size: size, relativeTo: style)
            : .system(size: size, weight: .regular)
    }

    /// A screen's title.
    static var screenTitle: Font { display(30) }
    /// The title of a setup step.
    static var headline1: Font { display(32) }
    /// A group's title above its card.
    static var groupTitle: Font { .system(size: 12, weight: .semibold) }
    /// A row's title.
    static var rowTitle: Font { .system(size: 13) }
    /// A row's second line.
    static var rowDetail: Font { .system(size: 11.5) }
}
