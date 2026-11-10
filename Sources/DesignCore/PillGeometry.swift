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

/// What the top of a screen holds, which decides the pill's shape (ARCHITECTURE.md, section 8, "The pill").
public enum HousingKind: Equatable, Sendable {
    /// A camera island narrower than `PillGeometry.islandLimit`: the pill is a black capsule that grows out of it.
    case island
    /// A wider notch: the pill is a black shape flush with the top of the screen that widens it.
    case notch
    /// No housing: the pill floats under the menu bar in the pill colour, edged with a hairline.
    case none
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

    /// The housing the pill grows out of: none without a reported band or a housing with width.
    public var kind: HousingKind {
        guard let housing, housing.width > 0, safeAreaTop > 0 else { return .none }
        return housing.width < PillGeometry.islandLimit ? .island : .notch
    }

    public var description: String {
        let housing = housing.map { "x \($0.minX) to \($0.maxX) (\($0.width) pt)" } ?? "none"
        return "screen \(frame.width) x \(frame.height) pt at (\(frame.minX), \(frame.minY)), scale \(scale), "
            + "safe-area top \(safeAreaTop), menu bar \(menuBarHeight), housing \(housing), kind \(kind)"
    }
}

/// The two hidden settings that nudge the island pill (ARCHITECTURE.md, section 8): `NSScreen` reports the housing's
/// band, not its outline, so its height and vertical position are checked by eye on the hardware.
public struct PillAdjustments: Equatable, Sendable {
    /// Points added to the island pill's height, within ±`limit`.
    public var islandHeight: Double
    /// Points the island pill moves down (negative: up), within ±`limit`.
    public var islandOffset: Double

    public static let limit = 8.0

    public init(islandHeight: Double = 0, islandOffset: Double = 0) {
        self.islandHeight = islandHeight
        self.islandOffset = islandOffset
    }

    var clampedHeight: Double { islandHeight.isFinite ? min(max(islandHeight, -Self.limit), Self.limit) : 0 }
    var clampedOffset: Double { islandOffset.isFinite ? min(max(islandOffset, -Self.limit), Self.limit) : 0 }
}

/// The pill's outline: a rectangle whose top and bottom corners are rounded, each pair by its own radius. A capsule
/// has both radii half its height; a body flush with the top of the screen has square top corners.
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
    /// The housing's own footprint (a small dot where there is none): where the pill grows from and shrinks back to.
    case rest
    /// The wave in the leading wing, and in the trailing wing content `trailing` points wide (the elapsed time, with the
    /// prompt tag before it). `cancel`: toggle mode, with the cancel bud beside the pill.
    case listening(trailing: Double, cancel: Bool)
    /// The shimmer, and in the trailing wing content `trailing` points wide (the words "Preparing model"), if any.
    case waiting(trailing: Double?)
    /// A card holding content of this size (`NoticeLayout.size`).
    case notice(CGSize)
}

/// Where everything goes for one form on one screen. Every rectangle is in the screen's points from its top left, y
/// down, on whole pixels.
public struct PillLayout: Equatable, Sendable {
    public var kind: HousingKind
    public var body: PillBody
    /// The housing's footprint inside the body, where nothing is laid out; nil where there is none.
    public var housing: CGRect?
    /// The wave or the shimmer.
    public var leading: CGRect?
    /// The elapsed time, the words of the wait, or the shimmer's second half beside a housing.
    public var trailing: CGRect?
    /// The notice's content.
    public var card: CGRect?
    /// The cancel bud's resting circle.
    public var cancel: CGRect?
}

/// The pill's geometry (ARCHITECTURE.md, section 8, "The pill"): from the screen, the form and the two adjustments
/// to the body's outline and the regions its content goes in. One pure function, so every housing and every form can
/// be tested for the invariants the pill must keep.
public enum PillGeometry {
    /// A housing narrower than this is an island; a wider one is a notch.
    public static let islandLimit = 110.0
    /// The island pill's height before adjustment.
    public static let islandHeight = 32.0
    /// The floating pill's height, and its distance under the menu bar.
    public static let floatingHeight = 36.0
    public static let floatingGap = 8.0
    /// The notch's lower corners at rest (the hardware's), when widened, and as a card.
    public static let notchRestRadius = 8.0
    public static let notchRadius = 10.0
    public static let cardRadius = 20.0
    /// Between content and the housing, and between content and the body's ends.
    public static let housingGap = 8.0
    public static let endPadding = 12.0
    /// Between the two wings where there is no housing.
    public static let floatingSplit = 14.0
    /// The wave's width, and the shimmer's in each wing (the whole row where there is no housing).
    public static let waveWidth = 88.0
    public static let shimmerWidth = 52.0
    public static let floatingShimmerWidth = 96.0
    /// Between the body and the cancel bud at rest, over the neck's reach so it has pinched free; and how much smaller
    /// than the body's height the bud is.
    public static let budGap = 12.0
    public static let budInset = 8.0
    /// The body never comes nearer the screen's sides than this.
    public static let screenMargin = 8.0
    /// The card's padding: at the sides, under the band (or above the content where there is none), and at the bottom.
    public static let cardPadding = 16.0
    public static let cardTopGap = 10.0
    public static let cardBottom = 14.0
    public static let cardMinWidth = 240.0
    public static let cardMaxWidth = 520.0

    /// The widest a notice's content may be on `screen`: the UI truncates its text to fit.
    public static func maximumCardContent(on screen: ScreenTopology) -> Double {
        max(min(cardMaxWidth, screen.width - 2 * screenMargin) - 2 * cardPadding, 0)
    }

    /// Where the pill's parts go for `form` on `screen`.
    public static func layout(_ form: PillForm, on screen: ScreenTopology,
                              adjustments: PillAdjustments = PillAdjustments()) -> PillLayout {
        let scale = screen.scale.isFinite && screen.scale > 0 ? screen.scale : 1
        let grid = Grid(scale: scale)
        let line = band(on: screen, adjustments: adjustments, grid: grid)
        switch form {
        case .rest:
            return PillLayout(kind: line.kind, body: rest(line), housing: line.housing, leading: nil, trailing: nil,
                              card: nil, cancel: nil)
        case .listening(let trailing, let cancel):
            return wings(leading: waveWidth, trailing: trailing, cancel: cancel, line, screen, grid)
        case .waiting(let trailing):
            if let trailing {
                return wings(leading: shimmerWidth, trailing: trailing, cancel: false, line, screen, grid)
            }
            // The row alone: beside a housing it runs through both wings, behind the housing.
            return wings(leading: line.housing == nil ? floatingShimmerWidth : shimmerWidth,
                         trailing: line.housing == nil ? 0 : shimmerWidth, cancel: false, line, screen, grid)
        case .notice(let size):
            return card(size, line, screen, grid)
        }
    }

    // MARK: - The band the pill sits in

    /// The pill's horizontal line on a screen: where its middle is, how tall it is there, and the housing it must
    /// contain.
    private struct Line {
        var kind: HousingKind
        var housing: CGRect?
        /// The middle's x, the body's top and height in its wing forms, and the bottom of the band content must clear.
        var midX: Double
        var top: Double
        var height: Double
        var bandBottom: Double
        var topRadius: Double
        var bottomRadius: Double
    }

    private static func band(on screen: ScreenTopology, adjustments: PillAdjustments, grid: Grid) -> Line {
        switch screen.kind {
        case .island:
            let span = screen.housing ?? HousingSpan(minX: 0, maxX: 0)
            let height = grid.round(min(max(islandHeight + adjustments.clampedHeight, 16), screen.safeAreaTop + 16))
            let top = grid.round((screen.safeAreaTop - height) / 2 + adjustments.clampedOffset)
            let minX = grid.down(span.minX), maxX = grid.up(span.maxX)
            let housing = CGRect(x: minX, y: top, width: maxX - minX, height: height)
            return Line(kind: .island, housing: housing, midX: (minX + maxX) / 2, top: top, height: height,
                        bandBottom: max(screen.safeAreaTop, top + height), topRadius: height / 2,
                        bottomRadius: height / 2)
        case .notch:
            let span = screen.housing ?? HousingSpan(minX: 0, maxX: 0)
            let height = grid.up(screen.safeAreaTop)
            let minX = grid.down(span.minX), maxX = grid.up(span.maxX)
            let housing = CGRect(x: minX, y: 0, width: maxX - minX, height: height)
            return Line(kind: .notch, housing: housing, midX: (minX + maxX) / 2, top: 0, height: height,
                        bandBottom: height, topRadius: 0, bottomRadius: notchRadius)
        case .none:
            let top = grid.round(max(screen.menuBarHeight, 0) + floatingGap)
            return Line(kind: .none, housing: nil, midX: grid.round(screen.width / 2), top: top,
                        height: floatingHeight, bandBottom: top, topRadius: floatingHeight / 2,
                        bottomRadius: floatingHeight / 2)
        }
    }

    private static func rest(_ line: Line) -> PillBody {
        guard let housing = line.housing else {
            let side = line.height
            return PillBody(frame: CGRect(x: line.midX - side / 2, y: line.top, width: side, height: side),
                            topRadius: side / 2, bottomRadius: side / 2)
        }
        let bottom = line.kind == .notch ? notchRestRadius : line.bottomRadius
        return PillBody(frame: housing, topRadius: line.topRadius, bottomRadius: bottom)
    }

    // MARK: - Wings

    private static func wings(leading: Double, trailing: Double, cancel: Bool, _ line: Line,
                              _ screen: ScreenTopology, _ grid: Grid) -> PillLayout {
        let budDiameter = grid.round(max(line.height - budInset, 12))
        let budRoom = cancel ? budGap + budDiameter : 0
        let leadingWant = sane(leading), trailingWant = sane(trailing)
        var layout: PillLayout
        if let housing = line.housing {
            // Both wings the same width, so the body is symmetric about the housing.
            let room = min(Double(housing.minX) - screenMargin,
                           screen.width - Double(housing.maxX) - screenMargin - budRoom) - housingGap - endPadding
            let wing = max(min(grid.up(max(leadingWant, trailingWant)), grid.down(room)), 0)
            let leadingBox = CGRect(x: Double(housing.minX) - housingGap - wing, y: line.top, width: wing,
                                    height: line.height)
            let trailingBox = CGRect(x: Double(housing.maxX) + housingGap, y: line.top, width: wing,
                                     height: line.height)
            let frame = CGRect(x: Double(leadingBox.minX) - endPadding, y: line.top,
                               width: Double(trailingBox.maxX) + endPadding - (Double(leadingBox.minX) - endPadding),
                               height: line.height)
            layout = PillLayout(kind: line.kind, body: PillBody(frame: frame, topRadius: line.topRadius,
                                                                bottomRadius: line.bottomRadius),
                                housing: housing, leading: leadingBox, trailing: trailingBox, card: nil, cancel: nil)
        } else {
            // No housing: the leading content, a gap, the trailing content, centred on the screen.
            let gap = trailingWant > 0 ? floatingSplit : 0
            let room = screen.width - 2 * screenMargin - 2 * endPadding - gap - 2 * budRoom
            var leadingWidth = grid.up(leadingWant), trailingWidth = grid.up(trailingWant)
            if leadingWidth + trailingWidth > room {
                // The text keeps what it can; the wave or shimmer gives way first.
                trailingWidth = grid.down(max(min(trailingWidth, room / 2), 0))
                leadingWidth = grid.down(max(room - trailingWidth, 0))
            }
            let width = 2 * endPadding + leadingWidth + gap + trailingWidth
            let minX = grid.round(line.midX - width / 2)
            let frame = CGRect(x: minX, y: line.top, width: width, height: line.height)
            let leadingBox = CGRect(x: minX + endPadding, y: line.top, width: leadingWidth, height: line.height)
            let trailingBox = trailingWidth > 0
                ? CGRect(x: Double(leadingBox.maxX) + gap, y: line.top, width: trailingWidth, height: line.height)
                : nil
            layout = PillLayout(kind: .none, body: PillBody(frame: frame, topRadius: line.topRadius,
                                                            bottomRadius: line.bottomRadius),
                                housing: nil, leading: leadingBox, trailing: trailingBox, card: nil, cancel: nil)
        }
        if cancel {
            let frame = layout.body.frame
            let midY = Double(frame.midY)
            layout.cancel = CGRect(x: Double(frame.maxX) + budGap, y: grid.round(midY - budDiameter / 2),
                                   width: budDiameter, height: budDiameter)
        }
        return layout
    }

    // MARK: - Card

    private static func card(_ size: CGSize, _ line: Line, _ screen: ScreenTopology, _ grid: Grid) -> PillLayout {
        let contentWidth = grid.up(min(sane(Double(size.width)), maximumCardContent(on: screen)))
        let contentHeight = grid.up(sane(Double(size.height)))
        let widest = max(min(cardMaxWidth, screen.width - 2 * screenMargin), 0)
        var width = max(contentWidth + 2 * cardPadding, cardMinWidth)
        if let housing = line.housing { width = max(width, Double(housing.width) + 2 * (housingGap + endPadding + 24)) }
        width = grid.down(min(width, widest))
        let top: Double, contentTop: Double, radii: (Double, Double)
        switch line.kind {
        case .island:
            top = line.top
            contentTop = grid.up(line.bandBottom + cardTopGap)
            radii = (line.topRadius, cardRadius)
        case .notch:
            top = 0
            contentTop = grid.up(line.bandBottom + cardTopGap)
            radii = (0, cardRadius)
        case .none:
            top = line.top
            contentTop = grid.round(line.top + cardBottom)
            radii = (cardRadius, cardRadius)
        }
        let height = contentTop + contentHeight + cardBottom - top
        var minX = grid.round(line.midX - width / 2)
        minX = min(max(minX, grid.up(screenMargin)), grid.down(screen.width - screenMargin - width))
        let frame = CGRect(x: minX, y: top, width: width, height: height)
        let content = CGRect(x: grid.round(Double(frame.midX) - contentWidth / 2), y: contentTop, width: contentWidth,
                             height: contentHeight)
        return PillLayout(kind: line.kind, body: PillBody(frame: frame, topRadius: radii.0, bottomRadius: radii.1),
                          housing: line.housing, leading: nil, trailing: nil, card: content, cancel: nil)
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
/// text on the first row, up to three capsule actions centred on the second. Rectangles are from the content's top
/// left, on whole pixels.
public struct NoticeLayout: Equatable, Sendable {
    public static let symbolGap = 8.0
    public static let rowGap = 12.0
    public static let actionGap = 8.0
    public static let maximumActions = 3

    public var size: CGSize
    public var symbol: CGRect
    /// The text's box: narrower than its measured width when it must be truncated.
    public var text: CGRect
    public var actions: [CGRect]

    /// Lays out a symbol, a line of text and the actions, as the UI measured them, in at most `maxWidth` points. The
    /// text gives way first; actions beyond the third are dropped; actions that together do not fit share the width.
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

        var widths = actions.prefix(Self.maximumActions).map { clean($0).w }
        let actionHeight = actions.prefix(Self.maximumActions).map { clean($0).h }.max() ?? 0
        let gaps = Double(max(widths.count - 1, 0)) * Self.actionGap
        if widths.reduce(0, +) + gaps > maxWidth, !widths.isEmpty {
            let share = grid.down(max((maxWidth - gaps) / Double(widths.count), 0))
            widths = widths.map { min($0, share) }
        }
        let secondWidth = widths.reduce(0, +) + (widths.isEmpty ? 0 : gaps)
        let width = max(firstWidth, secondWidth)
        let height = firstHeight + (widths.isEmpty ? 0 : Self.rowGap + actionHeight)
        size = CGSize(width: width, height: height)

        var x = grid.round((width - firstWidth) / 2)
        self.symbol = CGRect(x: x, y: grid.round((firstHeight - symbolSize.h) / 2), width: symbolSize.w,
                             height: symbolSize.h)
        x += symbolSize.w + gap
        self.text = CGRect(x: x, y: grid.round((firstHeight - textSize.h) / 2), width: textWidth, height: textSize.h)
        var actionX = grid.round((width - secondWidth) / 2)
        var rects: [CGRect] = []
        for w in widths {
            rects.append(CGRect(x: actionX, y: firstHeight + Self.rowGap, width: w, height: actionHeight))
            actionX += w + Self.actionGap
        }
        self.actions = rects
    }
}
