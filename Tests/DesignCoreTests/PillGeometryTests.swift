import CoreGraphics
import DesignCore
import Foundation
import Testing

/// ARCHITECTURE.md, section 8, "The pill": one pill on every screen, hung below the top band and centred on the camera
/// housing where there is one, checked against real Macs and held to the invariants every form must keep.
@Suite struct PillGeometryTests {
    /// The 2026 MacBook Pro, as its screen reports itself: a camera housing 59 pt wide in a 40 pt band, under a menu
    /// bar 45 pt tall. The menu bar is the taller, so the pill hangs from it.
    static let island = ScreenTopology(frame: CGRect(x: 0, y: 0, width: 1736, height: 1133), safeAreaTop: 40,
                                       leftAreaWidth: 838.5, rightAreaWidth: 1736 - 897.5, menuBarHeight: 45,
                                       scale: 2)
    /// A 14-inch 2021 MacBook Pro at its default scale: a notch about 185 pt wide in a 32 pt band.
    static let notch = ScreenTopology(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                      leftAreaWidth: 663.5, rightAreaWidth: 663.5, menuBarHeight: 32, scale: 2)
    /// An external display, at 2x and at 1x, beside the built-in one.
    static let external = ScreenTopology(frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), safeAreaTop: 0,
                                         housing: nil, menuBarHeight: 24, scale: 2)
    static let externalAt1x = ScreenTopology(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
                                             housing: nil, menuBarHeight: 25, scale: 1)
    /// An island on a 1x screen, with its edges between pixels, so the geometry has to snap them.
    static let islandAt1x = ScreenTopology(frame: CGRect(x: 0, y: 0, width: 1200, height: 800), safeAreaTop: 33,
                                           leftAreaWidth: 570.3, rightAreaWidth: 570.6, menuBarHeight: 33, scale: 1)
    /// A notch whose band is taller than the menu bar, and a menu bar taller than the notch's band (a larger menu bar
    /// text size): the pill hangs below whichever is taller.
    static let tallBand = ScreenTopology(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 38,
                                         leftAreaWidth: 663.5, rightAreaWidth: 663.5, menuBarHeight: 24, scale: 2)
    static let tallMenuBar = ScreenTopology(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                            leftAreaWidth: 663.5, rightAreaWidth: 663.5, menuBarHeight: 37.5,
                                            scale: 2)
    /// Narrow screens: the pill must shrink to stay on them.
    static let narrowIsland = ScreenTopology(frame: CGRect(x: 0, y: 0, width: 280, height: 500), safeAreaTop: 40,
                                             leftAreaWidth: 110.5, rightAreaWidth: 110.5, menuBarHeight: 40, scale: 2)
    static let narrowNotch = ScreenTopology(frame: CGRect(x: 0, y: 0, width: 420, height: 500), safeAreaTop: 32,
                                            leftAreaWidth: 117.5, rightAreaWidth: 117.5, menuBarHeight: 32, scale: 2)
    static let narrowExternal = ScreenTopology(frame: CGRect(x: 0, y: 0, width: 200, height: 400), safeAreaTop: 0,
                                               housing: nil, menuBarHeight: 24, scale: 1)

    static let screens = [island, notch, external, externalAt1x, islandAt1x, tallBand, tallMenuBar, narrowIsland,
                          narrowNotch, narrowExternal]
    static let forms: [PillForm] = [
        .rest, .listening(trailing: 30, cancel: false), .listening(trailing: 34.5, cancel: false),
        .listening(trailing: 52, cancel: true), .listening(trailing: 300, cancel: true), .waiting(trailing: nil),
        .waiting(trailing: 104.3), .notice(CGSize(width: 260.7, height: 58.2)),
        .notice(CGSize(width: 4000, height: 20)), .notice(CGSize(width: 10, height: 10)),
    ]

    static func onPixels(_ rect: CGRect, _ scale: Double) -> Bool {
        [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy { v in
            let scaled = Double(v) * scale
            return abs(scaled - scaled.rounded()) < 1e-6
        }
    }

    static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        inner.minX >= outer.minX - 1e-9 && inner.maxX <= outer.maxX + 1e-9
            && inner.minY >= outer.minY - 1e-9 && inner.maxY <= outer.maxY + 1e-9
    }

    /// The foot of the top band on the screen's pixel grid: no form reaches above it.
    static func foot(_ screen: ScreenTopology) -> Double {
        (screen.topBand * screen.scale - 1e-6).rounded(.up) / screen.scale
    }

    @Test func theHousingFollowsTheAuxiliaryAreas() {
        #expect(Self.island.housing == HousingSpan(minX: 838.5, maxX: 897.5))
        #expect(Self.island.middle == 868)
        #expect(Self.notch.housing?.width == 185)
        #expect(Self.notch.middle == 756)
        #expect(Self.external.housing == nil)
        #expect(Self.external.middle == 1280)
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // A housing counts only if both areas exist and leave a gap between them; without one the middle is the
        // screen's.
        for (left, right) in [(nil, 600.0), (600.0, nil), (756.0, 756.0), (800.0, 800.0)] as [(Double?, Double?)] {
            let screen = ScreenTopology(frame: frame, safeAreaTop: 32, leftAreaWidth: left, rightAreaWidth: right,
                                        menuBarHeight: 24, scale: 2)
            #expect(screen.housing == nil)
            #expect(screen.middle == 756)
        }
        // An island and a notch of any width are the same kind of thing: a span with a middle.
        let lopsided = ScreenTopology(frame: frame, safeAreaTop: 32, leftAreaWidth: 700, rightAreaWidth: 712,
                                      menuBarHeight: 32, scale: 2)
        #expect(lopsided.housing == HousingSpan(minX: 700, maxX: 800))
        #expect(lopsided.middle == 750)
    }

    /// The top band is the menu bar, or the housing's band where that is taller.
    @Test func theTopBandIsTheTallerOfTheMenuBarAndTheHousingsBand() {
        #expect(Self.island.topBand == 45)
        #expect(Self.external.topBand == 24)
        #expect(Self.tallBand.topBand == 38)
        #expect(Self.tallMenuBar.topBand == 37.5)
        let odd = ScreenTopology(frame: CGRect(x: 0, y: 0, width: 800, height: 600), safeAreaTop: .nan, housing: nil,
                                 menuBarHeight: -3, scale: 2)
        #expect(odd.topBand == 0)
    }

    /// On the 2026 MacBook Pro the listening pill is a 156 pt capsule 8 pt below the menu bar, centred on the camera:
    /// the wave, then the time. It used to be a black shape about 274 pt wide that grew sideways out of the housing.
    @Test func onTheIslandMacThePillHangsBelowTheCamera() {
        let listening = PillGeometry.layout(.listening(trailing: 30, cancel: false), on: Self.island)
        #expect(listening.body == PillBody(frame: CGRect(x: 790, y: 53, width: 156, height: 36), topRadius: 18,
                                           bottomRadius: 18))
        #expect(listening.leading == CGRect(x: 802, y: 53, width: 88, height: 36))
        #expect(listening.trailing == CGRect(x: 904, y: 53, width: 30, height: 36))
        #expect(listening.card == nil && listening.cancel == nil)
        // In toggle mode the bud hangs off the trailing end and the body stays where it was.
        let toggle = PillGeometry.layout(.listening(trailing: 30, cancel: true), on: Self.island)
        #expect(toggle.body == listening.body)
        #expect(toggle.cancel == CGRect(x: 958, y: 57, width: 28, height: 28))
    }

    /// The drop starts from a small capsule touching the foot of the band, centred under the camera.
    @Test func theRestIsASmallCapsuleUnderTheCamera() {
        let rest = PillGeometry.layout(.rest, on: Self.island)
        let width = PillGeometry.restWidth, height = PillGeometry.restHeight
        #expect(rest.body == PillBody(frame: CGRect(x: 868 - width / 2, y: 45, width: width, height: height),
                                      topRadius: height / 2, bottomRadius: height / 2))
        #expect(rest.leading == nil && rest.trailing == nil && rest.card == nil && rest.cancel == nil)
        #expect(height < PillGeometry.height)
    }

    /// The same content gives the same pill on the island Mac, the notch Mac and the external display: the same size,
    /// the same corners and the same regions inside it, each placed by its screen's band and middle.
    @Test func anIslandANotchAndNoHousingGetTheSamePill() {
        for form in Self.forms {
            let layouts = [Self.island, Self.notch, Self.external].map { PillGeometry.layout(form, on: $0) }
            for (screen, layout) in zip([Self.island, Self.notch, Self.external], layouts) {
                let body = layout.body.frame
                #expect(abs(Double(body.midX) - screen.middle) <= 0.25, "\(form) is off the middle of \(screen)")
                let gap = form == .rest ? 0 : PillGeometry.gap
                #expect(Double(body.minY) == screen.topBand + gap, "\(form) does not hang from the band")
            }
            func shape(_ layout: PillLayout) -> [CGRect?] {
                let origin = layout.body.frame.origin
                return [layout.body.frame, layout.leading, layout.trailing, layout.card, layout.cancel].map {
                    $0?.offsetBy(dx: -origin.x, dy: -origin.y)
                }
            }
            let first = layouts[0]
            for layout in layouts.dropFirst() {
                #expect(shape(layout) == shape(first), "\(form) differs between screens")
                #expect(layout.body.topRadius == first.body.topRadius)
                #expect(layout.body.bottomRadius == first.body.bottomRadius)
            }
        }
    }

    /// Every form on every screen: the body never reaches into the top band, and every form but the rest hangs exactly
    /// 8 pt below it; the body is centred on the middle unless a side of the screen holds it back; content lies inside
    /// the body; everything stays on screen with the margin; every edge is on a whole pixel; the wave and wait forms
    /// are capsules, the bud a circle beside the body; and the rest lies inside every form's span.
    @Test(arguments: Self.screens)
    func everyFormKeepsTheInvariants(screen: ScreenTopology) throws {
        let foot = Self.foot(screen)
        let rest = PillGeometry.layout(.rest, on: screen).body.frame
        let margin = PillGeometry.screenMargin
        for form in Self.forms {
            let layout = PillGeometry.layout(form, on: screen)
            let body = layout.body.frame
            let regions = [layout.leading, layout.trailing, layout.card, layout.cancel].compactMap { $0 }
            #expect(Double(body.minY) >= foot - 1e-9, "\(form) reaches into the band on \(screen)")
            if case .rest = form {
                #expect(Double(body.minY) == foot)
            } else {
                #expect(Double(body.minY) == foot + PillGeometry.gap, "\(form) is not 8 pt below the band")
            }
            let right = Double(layout.cancel?.maxX ?? body.maxX)
            if Double(body.minX) > margin + 1e-9, right < screen.width - margin - 1e-9 {
                #expect(abs(Double(body.midX) - screen.middle) <= 0.5 / screen.scale + 1e-9,
                        "\(form) is off the middle of \(screen)")
            }
            for region in [layout.leading, layout.trailing, layout.card].compactMap({ $0 }) {
                #expect(Self.contains(body, region), "\(form): content outside the body")
            }
            #expect(Double(body.minX) >= margin - 1e-9 && right <= screen.width - margin + 1e-9,
                    "\(form): off screen on \(screen)")
            for rect in [body] + regions {
                #expect(rect.minY >= 0 && Double(rect.maxY) <= screen.height)
                #expect(Self.onPixels(rect, screen.scale), "\(form): \(rect) is between pixels at \(screen.scale)x")
            }
            switch form {
            case .notice:
                #expect(layout.body.topRadius == PillGeometry.cardRadius)
                #expect(layout.body.bottomRadius == PillGeometry.cardRadius)
            case .rest, .listening, .waiting:
                #expect(layout.body.topRadius == Double(body.height) / 2, "\(form) is not a capsule")
                #expect(layout.body.bottomRadius == Double(body.height) / 2, "\(form) is not a capsule")
            }
            if let cancel = layout.cancel {
                #expect(cancel.width == cancel.height)
                #expect(Double(cancel.minX - body.maxX) == PillGeometry.budGap)
                #expect(abs(cancel.midY - body.midY) <= 0.5 / screen.scale + 1e-9)
            }
            #expect(rest.minX >= body.minX - 1e-9 && rest.maxX <= body.maxX + 1e-9,
                    "the rest pokes out of \(form) on \(screen)")
        }
    }

    /// The listening body depends only on what it holds: the bud never moves it, the same time's width never changes
    /// it, and a wider time (one that gained a digit) widens it about the same middle.
    @Test func listeningHoldsStillUntilTheTimeWidens() {
        for screen in [Self.island, Self.notch, Self.external] {
            let hold = PillGeometry.layout(.listening(trailing: 28, cancel: false), on: screen)
            let toggle = PillGeometry.layout(.listening(trailing: 28, cancel: true), on: screen)
            #expect(hold.body == toggle.body && hold.leading == toggle.leading && hold.trailing == toggle.trailing)
            let wider = PillGeometry.layout(.listening(trailing: 36, cancel: false), on: screen)
            #expect(wider.body.frame.width == hold.body.frame.width + 8)
            #expect(abs(wider.body.frame.midX - hold.body.frame.midX) <= 0.25)
            #expect(wider.leading?.width == hold.leading?.width, "the wave gave way on a wide screen")
        }
    }

    /// On a screen too narrow for the content the wave or the wait's row gives way first, down to room for a few
    /// dots, and only then is the text truncated.
    @Test func aNarrowScreenNarrowsTheRowBeforeTheText() throws {
        let waiting = PillGeometry.layout(.waiting(trailing: 104.3), on: Self.narrowExternal)
        let row = try #require(waiting.leading), words = try #require(waiting.trailing)
        #expect(Double(row.width) < PillGeometry.shortShimmerWidth && Double(row.width) >= PillGeometry.leastLeading)
        #expect(words.width == 105, "the words were cut while the row could still give way")
        let long = PillGeometry.layout(.listening(trailing: 300, cancel: true), on: Self.narrowExternal)
        #expect(Double(try #require(long.leading).width) == PillGeometry.leastLeading)
        let time = try #require(long.trailing)
        #expect(time.width > 0 && time.width < 300)
    }

    /// A suggestion's four actions, wrapping for a long app name, on every screen: every action lies in the card,
    /// below the band, inside the screen's margins, on whole pixels.
    @Test(arguments: Self.screens)
    func fourActionsFitTheCardOnEveryScreen(screen: ScreenTopology) throws {
        for titles in [[126.0, 121, 77, 111], [262, 121, 77, 111]] {
            let notice = NoticeLayout(symbol: CGSize(width: 18, height: 18), text: CGSize(width: 260, height: 16),
                                      actions: titles.map { CGSize(width: $0, height: 26) },
                                      maxWidth: PillGeometry.maximumCardContent(on: screen), scale: screen.scale)
            let layout = PillGeometry.layout(.notice(notice.size), on: screen)
            let card = try #require(layout.card)
            #expect(notice.actions.count == 4)
            // No title is cut unless it alone is wider than the card allows, even on the narrowest screen.
            let widest = PillGeometry.maximumCardContent(on: screen)
            #expect(notice.actions.map { Double($0.width) } == titles.map { min($0, (widest * screen.scale)
                .rounded(.down) / screen.scale) })
            for action in notice.actions {
                let frame = action.offsetBy(dx: card.minX, dy: card.minY)
                #expect(Self.contains(card, frame))
                #expect(Self.contains(layout.body.frame, frame))
                #expect(Double(frame.minY) >= Self.foot(screen) + PillGeometry.gap)
                #expect(Double(frame.minX) >= PillGeometry.screenMargin - 1e-9)
                #expect(Double(frame.maxX) <= screen.width - PillGeometry.screenMargin + 1e-9)
                #expect(Self.onPixels(frame, screen.scale), "\(frame) is between pixels")
            }
            #expect(Double(layout.body.frame.minX) >= PillGeometry.screenMargin - 1e-9)
            #expect(Double(layout.body.frame.maxX) <= screen.width - PillGeometry.screenMargin + 1e-9)
        }
    }

    /// A notice wider than the screen allows is narrowed to fit, and its text truncated by the layout inside it.
    @Test func aLongNoticeFitsTheScreen() throws {
        for screen in Self.screens {
            let widest = PillGeometry.maximumCardContent(on: screen)
            let card = try #require(PillGeometry.layout(.notice(CGSize(width: 4000, height: 20)), on: screen).card)
            #expect(Double(card.width) <= widest + 1e-9)
            let notice = NoticeLayout(symbol: CGSize(width: 16, height: 16), text: CGSize(width: 4000, height: 16),
                                      actions: [], maxWidth: widest, scale: screen.scale)
            #expect(Double(notice.size.width) <= widest + 1e-9)
            #expect(Double(notice.text.maxX) <= widest + 1e-9)
        }
    }
}

/// ARCHITECTURE.md, section 8, "Notice": a symbol, one line of text and up to three capsule actions.
@Suite struct NoticeLayoutTests {
    @Test func rowsAreCentredAndOnPixels() throws {
        let layout = NoticeLayout(symbol: CGSize(width: 15.3, height: 15), text: CGSize(width: 180.4, height: 16.2),
                                  actions: [CGSize(width: 50.2, height: 26), CGSize(width: 70, height: 26),
                                            CGSize(width: 96.6, height: 26)],
                                  maxWidth: 400, scale: 2)
        #expect(layout.actions.count == 3)
        #expect(Double(layout.symbol.maxX) + NoticeLayout.symbolGap == Double(layout.text.minX))
        let first = layout.text.maxX - layout.symbol.minX
        #expect(abs((layout.symbol.minX - 0) - (layout.size.width - layout.text.maxX)) <= 0.5)
        #expect(first <= layout.size.width)
        let actions = try #require(layout.actions.first?.minX)
        #expect(abs(actions - (layout.size.width - (layout.actions.last?.maxX ?? 0))) <= 0.5)
        #expect(layout.actions.allSatisfy { $0.minY >= layout.text.maxY })
        for rect in [layout.symbol, layout.text] + layout.actions {
            #expect(PillGeometryTests.onPixels(rect, 2))
            #expect(rect.minX >= 0 && rect.maxX <= layout.size.width + 1e-9 && rect.maxY <= layout.size.height + 1e-9)
        }
        // The symbol and the text share a middle line.
        #expect(abs(layout.symbol.midY - layout.text.midY) <= 0.5)
    }

    /// Today's three actions that fit lay out exactly as before four were allowed.
    @Test func threeActionsThatFitAreUnchanged() {
        let layout = NoticeLayout(symbol: CGSize(width: 15.3, height: 15), text: CGSize(width: 180.4, height: 16.2),
                                  actions: [CGSize(width: 50.2, height: 26), CGSize(width: 70, height: 26),
                                            CGSize(width: 96.6, height: 26)],
                                  maxWidth: 400, scale: 2)
        #expect(layout.size == CGSize(width: 233.5, height: 54.5))
        #expect(layout.actions == [CGRect(x: 0, y: 28.5, width: 50.5, height: 26),
                                   CGRect(x: 58.5, y: 28.5, width: 70, height: 26),
                                   CGRect(x: 136.5, y: 28.5, width: 97, height: 26)])
        #expect(layout.text == CGRect(x: 38.5, y: 0, width: 180.5, height: 16.5))
    }

    /// Four actions that fit share one row, in order, centred, at their own widths.
    @Test func fourActionsThatFitShareOneRow() throws {
        let widths = [126.0, 121, 77, 111]
        let layout = NoticeLayout(symbol: CGSize(width: 18, height: 18), text: CGSize(width: 240, height: 16),
                                  actions: widths.map { CGSize(width: $0, height: 26) }, maxWidth: 488, scale: 2)
        #expect(layout.actions.count == 4)
        #expect(Set(layout.actions.map(\.minY)).count == 1)
        #expect(layout.actions.map { Double($0.width) } == widths)
        for (a, b) in zip(layout.actions, layout.actions.dropFirst()) {
            #expect(Double(b.minX - a.maxX) == NoticeLayout.actionGap)
        }
        let first = try #require(layout.actions.first), last = try #require(layout.actions.last)
        #expect(abs(Double(first.minX) - Double(layout.size.width - last.maxX)) <= 0.5)
        #expect(Double(layout.size.height) == 18 + NoticeLayout.rowGap + 26)
    }

    /// Four actions too wide for one row (a long app name) wrap onto a second rather than truncate: every title keeps
    /// its width, each row fits and is centred, the rows are a gap apart, and the order reads left to right, top to
    /// bottom.
    @Test func fourActionsThatDoNotFitWrap() throws {
        for widths in [[226.0, 121, 77, 111], [200, 120, 90, 110], [150, 150, 150, 150]] {
            let maxWidth = 488.0
            let layout = NoticeLayout(symbol: CGSize(width: 18, height: 18), text: CGSize(width: 240, height: 16),
                                      actions: widths.map { CGSize(width: $0, height: 26) }, maxWidth: maxWidth,
                                      scale: 2)
            #expect(layout.actions.map { Double($0.width) } == widths, "a title was truncated")
            let rows = Dictionary(grouping: layout.actions, by: \.minY).sorted { $0.key < $1.key }
            #expect(rows.count == 2)
            let top = try #require(rows.first), bottom = try #require(rows.last)
            #expect(Double(bottom.key - top.key) == 26 + NoticeLayout.actionGap)
            for (_, row) in rows {
                let minX = try #require(row.map(\.minX).min()), maxX = try #require(row.map(\.maxX).max())
                #expect(Double(maxX - minX) <= maxWidth)
                #expect(abs(Double(minX) - Double(layout.size.width - maxX)) <= 0.5, "a row is off centre")
            }
            for (a, b) in zip(layout.actions, layout.actions.dropFirst()) {
                #expect(b.minY > a.minY || (b.minY == a.minY && b.minX > a.maxX), "the actions are out of order")
            }
            #expect(Double(layout.size.width) <= maxWidth)
            #expect(Double(layout.size.height) == 18 + NoticeLayout.rowGap + 2 * 26 + NoticeLayout.actionGap)
        }
        // Four split two and two, even with one long title, and three two over one: a calm block, not a lone
        // capsule over a long row. Only when two and two cannot fit does the split fall elsewhere.
        for (widths, firstRow) in [([150.0, 150, 150, 150], 2), ([202, 118, 78, 112], 2), ([230, 230, 120], 2),
                                   ([440, 60, 60, 60], 1)] {
            let layout = NoticeLayout(symbol: .zero, text: CGSize(width: 50, height: 16),
                                      actions: widths.map { CGSize(width: $0, height: 26) }, maxWidth: 488, scale: 1)
            #expect(layout.actions.filter { $0.minY == layout.actions[0].minY }.count == firstRow, "\(widths)")
            #expect(layout.actions.map { Double($0.width) } == widths)
        }
    }

    /// Only an action wider than the card is narrowed; the others keep their titles whole.
    @Test func onlyAnActionWiderThanTheCardIsNarrowed() {
        let layout = NoticeLayout(symbol: .zero, text: CGSize(width: 50, height: 16),
                                  actions: [CGSize(width: 500, height: 26), CGSize(width: 50, height: 26)],
                                  maxWidth: 300, scale: 2)
        #expect(layout.actions.map { Double($0.width) } == [300, 50])
        #expect(Double(layout.size.width) <= 300)
    }

    @Test func aFifthActionIsDroppedAndCrowdedActionsShare() {
        let five = NoticeLayout(symbol: .zero, text: CGSize(width: 50, height: 16),
                                actions: Array(repeating: CGSize(width: 60, height: 26), count: 5), maxWidth: 400,
                                scale: 2)
        #expect(five.actions.count == 4)
        let crowded = NoticeLayout(symbol: .zero, text: CGSize(width: 50, height: 16),
                                   actions: Array(repeating: CGSize(width: 200, height: 26), count: 3), maxWidth: 300,
                                   scale: 2)
        #expect(crowded.size.width <= 300)
        #expect(crowded.actions.allSatisfy { $0.width == 200 && $0.maxX <= 300 }, "a title that fits was cut")
        #expect(Set(crowded.actions.map(\.minY)).count == 3, "too narrow for two rows, each action takes its own")
        let rows = Set(crowded.actions.map(\.minY)).sorted()
        #expect(zip(rows, rows.dropFirst()).allSatisfy { Double($1 - $0) == 26 + NoticeLayout.actionGap })
        let none = NoticeLayout(symbol: CGSize(width: 16, height: 16), text: CGSize(width: 50, height: 16), actions: [],
                                maxWidth: 400, scale: 1)
        #expect(none.size.height == 16)
        let odd = NoticeLayout(symbol: CGSize(width: Double.nan, height: -1), text: CGSize(width: Double.infinity,
                                                                                            height: 16),
                               actions: [], maxWidth: .nan, scale: 0)
        #expect(odd.size.width == 0)
    }
}
