import CoreGraphics
import Foundation

/// A camera housing's horizontal extent at the top of a screen, in the screen's points from its left edge.
public struct HousingSpan: Equatable, Sendable {
    public var minX: Double
    public var maxX: Double

    public init(minX: Double, maxX: Double) {
        self.minX = minX
        self.maxX = maxX
    }

    public var width: Double { maxX - minX }
    public var midX: Double { (minX + maxX) / 2 }
}

/// What the pill needs to know about the screen it is on, as `NSScreen` reports it. Kept as plain numbers so the
/// geometry can be tested against real Macs without one.
public struct ScreenTopology: Equatable, Sendable, CustomStringConvertible {
    /// The screen's frame in the global coordinates the window server uses (origin at the bottom left of the main
    /// screen). The geometry uses only its size; the overlay uses its origin to place the panels.
    public var frame: CGRect
    /// The height of the band at the top of the screen that the housing occupies (`safeAreaInsets.top`); 0 without one.
    public var safeAreaTop: Double
    /// The housing's extent, when the screen reports both auxiliary areas and they leave a gap between them.
    public var housing: HousingSpan?
    /// The menu bar's height on this screen.
    public var menuBarHeight: Double
    /// Pixels per point.
    public var scale: Double

    public init(frame: CGRect, safeAreaTop: Double, housing: HousingSpan?, menuBarHeight: Double, scale: Double) {
        self.frame = frame
        self.safeAreaTop = safeAreaTop
        self.housing = housing
        self.menuBarHeight = menuBarHeight
        self.scale = scale
    }

    /// From the widths of the two auxiliary areas beside the housing (`auxiliaryTopLeftArea` and
    /// `auxiliaryTopRightArea`): the housing lies between the first's right edge and the second's left edge. A housing
    /// counts only if both areas exist and leave a gap between them.
    public init(frame: CGRect, safeAreaTop: Double, leftAreaWidth: Double?, rightAreaWidth: Double?,
                menuBarHeight: Double, scale: Double) {
        var housing: HousingSpan?
        if let left = leftAreaWidth, let right = rightAreaWidth, left.isFinite, right.isFinite,
           left >= 0, right >= 0, left + right < Double(frame.width) {
            housing = HousingSpan(minX: left, maxX: Double(frame.width) - right)
        }
        self.init(frame: frame, safeAreaTop: safeAreaTop, housing: housing, menuBarHeight: menuBarHeight, scale: scale)
    }

    public var width: Double { Double(frame.width) }
    public var height: Double { Double(frame.height) }

    /// The band at the top of the screen the pill never draws in: the menu bar, or the housing's band where that is
    /// taller.
    public var topBand: Double {
        [menuBarHeight, safeAreaTop].filter(\.isFinite).reduce(0, max)
    }

    /// The line the pill is centred on: the housing's middle where there is a housing, whatever its width, and the
    /// screen's middle where there is none.
    public var middle: Double { housing?.midX ?? width / 2 }

    public var description: String {
        let housing = housing.map { "x \($0.minX) to \($0.maxX) (\($0.width) pt)" } ?? "none"
        return "screen \(frame.width) x \(frame.height) pt at (\(frame.minX), \(frame.minY)), scale \(scale), "
            + "menu bar \(menuBarHeight), safe-area top \(safeAreaTop), top band \(topBand), housing \(housing)"
    }
}

/// The pill's outline: a rectangle whose top and bottom corners are rounded, each pair by its own radius. A capsule
/// has both radii half its height; a card has both its own.
public struct PillBody: Equatable, Sendable {
    /// In the screen's points, from its top left, y down.
    public var frame: CGRect
    public var topRadius: Double
    public var bottomRadius: Double

    public init(frame: CGRect, topRadius: Double, bottomRadius: Double) {
        self.frame = frame
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    /// The radii as they can be drawn: never more than half the width, and together never more than the height.
    public var drawnRadii: (top: Double, bottom: Double) {
        let w = max(Double(frame.width), 0), h = max(Double(frame.height), 0)
        var top = min(max(topRadius, 0), w / 2), bottom = min(max(bottomRadius, 0), w / 2)
        if top + bottom > h, top + bottom > 0 {
            let k = h / (top + bottom)
            top *= k
            bottom *= k
        }
        return (top, bottom)
    }
}

/// A form of the pill, with the sizes of what it holds as the UI measured them.
public enum PillForm: Equatable, Sendable {
    /// A small capsule touching the foot of the top band, under the housing: where the pill drops from and goes back
    /// up to.
    case rest
    /// The wave, then content `trailing` points wide (the elapsed time, with the prompt tag before it). `cancel`:
    /// toggle mode, with the cancel bud beside the pill.
    case listening(trailing: Double, cancel: Bool)
    /// The wait's row, then content `trailing` points wide (the words "Preparing model"), if any.
    case waiting(trailing: Double?)
    /// A card holding content of this size (`NoticeLayout.size`).
    case notice(CGSize)
}

/// Where everything goes for one form on one screen. Every rectangle is in the screen's points from its top left, y
/// down, on whole pixels.
public struct PillLayout: Equatable, Sendable {
    public var body: PillBody
    /// The wave or the wait's row.
    public var leading: CGRect?
    /// The elapsed time, or the words of the wait.
    public var trailing: CGRect?
    /// The notice's content.
    public var card: CGRect?
    /// The cancel bud's resting circle.
    public var cancel: CGRect?
}

/// The pill's geometry (ARCHITECTURE.md, section 8, "The pill"): from the screen and the form to the body's outline
/// and the regions its content goes in. One pure function, so every screen and every form can be tested for the
/// invariants the pill must keep. There is one pill: the same content gives the same body on every screen wide enough
/// for it, hung `gap` below the top band and centred on the screen's middle.
public enum PillGeometry {
    /// The pill's height in every form but a card, and its distance below the top band.
    public static let height = 36.0
    public static let gap = 8.0
    /// The rest's size: small enough to lie inside every form, so the pill only ever grows out of it.
    public static let restWidth = 40.0
    public static let restHeight = 12.0
    /// Between content and the body's ends, and between the wave or the wait's row and what follows it.
    public static let endPadding = 12.0
    public static let split = 14.0
    /// The wave's width; the wait's row alone, and before the words of the wait.
    public static let waveWidth = 88.0
    public static let shimmerWidth = 96.0
    public static let shortShimmerWidth = 52.0
    /// The least the wave or the wait's row gives way to on a narrow screen before the text is truncated: room for a
    /// few dots.
    public static let leastLeading = 32.0
    /// Between the body and the cancel bud at rest, over the neck's reach so it has pinched free; and how much smaller
    /// than the body's height the bud is.
    public static let budGap = 12.0
    public static let budInset = 8.0
    /// The body never comes nearer the screen's sides than this.
    public static let screenMargin = 8.0
    /// The card's corners, its padding at the sides and above and below the content, and its widths.
    public static let cardRadius = 20.0
    public static let cardPadding = 16.0
    public static let cardVerticalPadding = 14.0
    public static let cardMinWidth = 240.0
    public static let cardMaxWidth = 520.0

    /// The widest a notice's content may be on `screen`: the UI truncates its text to fit.
    public static func maximumCardContent(on screen: ScreenTopology) -> Double {
        max(min(cardMaxWidth, screen.width - 2 * screenMargin) - 2 * cardPadding, 0)
    }

    /// Where the pill's parts go for `form` on `screen`.
    public static func layout(_ form: PillForm, on screen: ScreenTopology) -> PillLayout {
        let scale = screen.scale.isFinite && screen.scale > 0 ? screen.scale : 1
        let line = Line(screen: screen, grid: Grid(scale: scale))
        switch form {
        case .rest:
            return PillLayout(body: rest(line, screen), leading: nil, trailing: nil, card: nil, cancel: nil)
        case .listening(let trailing, let cancel):
            return capsule(leading: waveWidth, trailing: trailing, cancel: cancel, line, screen)
        case .waiting(let trailing):
            return capsule(leading: trailing == nil ? shimmerWidth : shortShimmerWidth, trailing: trailing ?? 0,
                           cancel: false, line, screen)
        case .notice(let size):
            return card(size, line, screen)
        }
    }

    // MARK: - The line the pill hangs from

    /// Where every form hangs on a screen, on its pixel grid: the foot of the top band, the top of every form below
    /// it, and the middle they are centred on.
    private struct Line {
        var grid: Grid
        var foot: Double
        var top: Double
        var middle: Double

        init(screen: ScreenTopology, grid: Grid) {
            self.grid = grid
            foot = grid.up(screen.topBand)
            top = foot + PillGeometry.gap
            middle = screen.middle.isFinite ? screen.middle : screen.width / 2
        }

        /// The left edge of a body `width` wide centred on the middle, held `right` points more than the margin from
        /// the screen's right side and the margin from its left.
        func minX(width: Double, right: Double, on screen: ScreenTopology) -> Double {
            let centred = grid.round(middle - width / 2)
            let highest = grid.down(screen.width - PillGeometry.screenMargin - right - width)
            return max(min(centred, highest), grid.up(PillGeometry.screenMargin))
        }
    }

    private static func rest(_ line: Line, _ screen: ScreenTopology) -> PillBody {
        let width = max(min(restWidth, line.grid.down(screen.width - 2 * screenMargin)), 0)
        let frame = CGRect(x: line.minX(width: width, right: 0, on: screen), y: line.foot, width: width,
                           height: restHeight)
        return PillBody(frame: frame, topRadius: restHeight / 2, bottomRadius: restHeight / 2)
    }

    // MARK: - The capsule

    /// The wave or the wait's row, a split, then the trailing content, between the end paddings, centred; the cancel
    /// bud beside the trailing end.
    private static func capsule(leading: Double, trailing: Double, cancel: Bool, _ line: Line,
                                _ screen: ScreenTopology) -> PillLayout {
        let grid = line.grid
        let budDiameter = grid.round(max(height - budInset, 12))
        let budRoom = cancel ? budGap + budDiameter : 0
        let gap = sane(trailing) > 0 ? split : 0
        // Room for both on either side of the middle, the bud's included, so the body stays centred.
        let room = max(screen.width - 2 * screenMargin - 2 * endPadding - gap - 2 * budRoom, 0)
        var leadingWidth = grid.up(sane(leading)), trailingWidth = grid.up(sane(trailing))
        if leadingWidth + trailingWidth > room {
            // The row gives way first, down to room for a few dots; then the text is truncated.
            leadingWidth = grid.down(max(room - trailingWidth, min(leadingWidth, leastLeading, room)))
            trailingWidth = grid.down(max(min(trailingWidth, room - leadingWidth), 0))
        }
        let width = 2 * endPadding + leadingWidth + gap + trailingWidth
        let minX = line.minX(width: width, right: budRoom, on: screen)
        let frame = CGRect(x: minX, y: line.top, width: width, height: height)
        let leadingBox = CGRect(x: minX + endPadding, y: line.top, width: leadingWidth, height: height)
        let trailingBox = trailingWidth > 0
            ? CGRect(x: Double(leadingBox.maxX) + gap, y: line.top, width: trailingWidth, height: height)
            : nil
        let bud = cancel
            ? CGRect(x: Double(frame.maxX) + budGap, y: grid.round(Double(frame.midY) - budDiameter / 2),
                     width: budDiameter, height: budDiameter)
            : nil
        return PillLayout(body: PillBody(frame: frame, topRadius: height / 2, bottomRadius: height / 2),
                          leading: leadingBox, trailing: trailingBox, card: nil, cancel: bud)
    }

    // MARK: - Card

    /// A rounded card hung from the same line as the capsule, as wide as its content and its padding (at least
    /// `cardMinWidth`), centred.
    private static func card(_ size: CGSize, _ line: Line, _ screen: ScreenTopology) -> PillLayout {
        let grid = line.grid
        let contentWidth = grid.up(min(sane(Double(size.width)), maximumCardContent(on: screen)))
        let contentHeight = grid.up(sane(Double(size.height)))
        let widest = max(min(cardMaxWidth, screen.width - 2 * screenMargin), 0)
        let width = grid.down(min(max(contentWidth + 2 * cardPadding, cardMinWidth), widest))
        let contentTop = line.top + cardVerticalPadding
        let frame = CGRect(x: line.minX(width: width, right: 0, on: screen), y: line.top, width: width,
                           height: 2 * cardVerticalPadding + contentHeight)
        let content = CGRect(x: grid.round(Double(frame.midX) - contentWidth / 2), y: contentTop, width: contentWidth,
                             height: contentHeight)
        return PillLayout(body: PillBody(frame: frame, topRadius: cardRadius, bottomRadius: cardRadius),
                          leading: nil, trailing: nil, card: content, cancel: nil)
    }

    private static func sane(_ value: Double) -> Double { value.isFinite ? max(value, 0) : 0 }
}

/// The screen's pixel grid: values rounded to whole pixels at its scale.
struct Grid {
    var scale: Double

    func round(_ value: Double) -> Double { (value * scale).rounded() / scale }
    func down(_ value: Double) -> Double { ((value * scale) + 1e-6).rounded(.down) / scale }
    func up(_ value: Double) -> Double { ((value * scale) - 1e-6).rounded(.up) / scale }
}

/// Where a notice's parts go inside its card (ARCHITECTURE.md, section 8, "Notice"): the symbol and one line of
/// text on the first row, then up to four capsule actions, centred on one row while they fit and on two when they do
/// not (on a screen too narrow for two, on as many as it takes). Rectangles are from the content's top left, on whole
/// pixels.
public struct NoticeLayout: Equatable, Sendable {
    public static let symbolGap = 8.0
    /// Between the line of text and the first row of actions.
    public static let rowGap = 12.0
    /// Between two actions side by side, and between the two rows of actions: the capsules sit on one even grid.
    public static let actionGap = 8.0
    public static let maximumActions = 4

    public var size: CGSize
    public var symbol: CGRect
    /// The text's box: narrower than its measured width when it must be truncated.
    public var text: CGRect
    /// In the order given, row by row.
    public var actions: [CGRect]

    /// Lays out a symbol, a line of text and the actions, as the UI measured them, in at most `maxWidth` points. The
    /// text gives way first. Actions beyond the fourth are dropped. Actions that do not fit on one row wrap onto a
    /// second, two and two (or two over one), and only on a screen too narrow for that onto more, so no title is
    /// truncated: an action is narrowed only if it alone is wider than `maxWidth`.
    public init(symbol: CGSize, text: CGSize, actions: [CGSize], maxWidth: Double, scale: Double) {
        let grid = Grid(scale: scale.isFinite && scale > 0 ? scale : 1)
        func clean(_ size: CGSize) -> (w: Double, h: Double) {
            let w = Double(size.width), h = Double(size.height)
            return (w.isFinite ? grid.up(max(w, 0)) : 0, h.isFinite ? grid.up(max(h, 0)) : 0)
        }
        let maxWidth = maxWidth.isFinite ? grid.down(max(maxWidth, 0)) : 0
        let symbolSize = clean(symbol), textSize = clean(text)
        let gap = symbolSize.w > 0 ? Self.symbolGap : 0
        let textWidth = max(min(textSize.w, maxWidth - symbolSize.w - gap), 0)
        let firstWidth = symbolSize.w + gap + textWidth
        let firstHeight = max(symbolSize.h, textSize.h)

        let shown = actions.prefix(Self.maximumActions).map(clean)
        let actionHeight = shown.map(\.h).max() ?? 0
        let rows = Self.rows(shown.map { min($0.w, maxWidth) }, maxWidth: maxWidth)
        let rowWidths = rows.map(Self.width)
        let width = max(firstWidth, rowWidths.max() ?? 0)
        let rowsHeight = rows.isEmpty ? 0
            : Self.rowGap + Double(rows.count) * actionHeight + Double(rows.count - 1) * Self.actionGap
        size = CGSize(width: width, height: firstHeight + rowsHeight)

        var x = grid.round((width - firstWidth) / 2)
        self.symbol = CGRect(x: x, y: grid.round((firstHeight - symbolSize.h) / 2), width: symbolSize.w,
                             height: symbolSize.h)
        x += symbolSize.w + gap
        self.text = CGRect(x: x, y: grid.round((firstHeight - textSize.h) / 2), width: textWidth, height: textSize.h)
        var rects: [CGRect] = []
        var y = firstHeight + Self.rowGap
        for (row, rowWidth) in zip(rows, rowWidths) {
            var actionX = grid.round((width - rowWidth) / 2)
            for w in row {
                rects.append(CGRect(x: actionX, y: y, width: w, height: actionHeight))
                actionX += w + Self.actionGap
            }
            y += actionHeight + Self.actionGap
        }
        self.actions = rects
    }

    /// A row's width: its actions and the gaps between them.
    private static func width(_ row: [Double]) -> Double {
        row.reduce(0, +) + Double(max(row.count - 1, 0)) * actionGap
    }

    /// The actions' widths in rows, in order: the fewest rows that each fit `maxWidth` (every action is at most that
    /// wide, so one per row always fits). Of the ways to fill that many rows, the one whose rows hold most nearly the
    /// same number of actions, the earlier rows the fuller, then the one whose widest row is narrowest.
    private static func rows(_ widths: [Double], maxWidth: Double) -> [[Double]] {
        guard !widths.isEmpty else { return [] }
        for count in 1 ... widths.count {
            let fitting = partitions(widths, into: count).filter { $0.allSatisfy { width($0) <= maxWidth } }
            func cost(_ rows: [[Double]]) -> (Int, [Int], Double) {
                let sizes = rows.map(\.count)
                return ((sizes.max() ?? 0) - (sizes.min() ?? 0), sizes.map { -$0 }, rows.map(width).max() ?? 0)
            }
            if let best = fitting.min(by: { a, b in
                let (x, y) = (cost(a), cost(b))
                if x.0 != y.0 { return x.0 < y.0 }
                if x.1 != y.1 { return x.1.lexicographicallyPrecedes(y.1) }
                return x.2 < y.2
            }) {
                return best
            }
        }
        return widths.map { [$0] }
    }

    /// Every way to cut `widths`, in order, into `count` non-empty rows.
    private static func partitions(_ widths: [Double], into count: Int) -> [[[Double]]] {
        guard count > 1 else { return widths.isEmpty ? [] : [[widths]] }
        guard widths.count >= count else { return [] }
        return (1 ... widths.count - count + 1).flatMap { cut in
            partitions(Array(widths[cut...]), into: count - 1).map { [Array(widths[..<cut])] + $0 }
        }
    }
}
