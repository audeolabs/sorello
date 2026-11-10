import CoreGraphics
import DesignCore
import Foundation
import Testing

/// ARCHITECTURE.md, section 8, "The pill": the pill's shape for each housing, checked against real Macs and held to
/// the invariants every form must keep.
@Suite struct PillGeometryTests {
    /// The 2026 MacBook Pro: a 59 pt island in a 40 pt band.
    static let island = ScreenTopology(frame: CGRect(x: 0, y: 0, width: 1736, height: 1133), safeAreaTop: 40,
                                       leftAreaWidth: 838.5, rightAreaWidth: 1736 - 897.5, menuBarHeight: 40,
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
    /// Narrow screens: the pill must shrink to stay on them.
    static let narrowIsland = ScreenTopology(frame: CGRect(x: 0, y: 0, width: 280, height: 500), safeAreaTop: 40,
                                             leftAreaWidth: 110.5, rightAreaWidth: 110.5, menuBarHeight: 40, scale: 2)
    static let narrowNotch = ScreenTopology(frame: CGRect(x: 0, y: 0, width: 420, height: 500), safeAreaTop: 32,
                                            leftAreaWidth: 117.5, rightAreaWidth: 117.5, menuBarHeight: 32, scale: 2)
    static let narrowExternal = ScreenTopology(frame: CGRect(x: 0, y: 0, width: 200, height: 400), safeAreaTop: 0,
                                               housing: nil, menuBarHeight: 24, scale: 1)

    static let screens = [island, notch, external, externalAt1x, islandAt1x, narrowIsland, narrowNotch, narrowExternal]
    static let forms: [PillForm] = [
        .rest, .listening(trailing: 34.5, cancel: false), .listening(trailing: 52, cancel: true),
        .listening(trailing: 300, cancel: true), .waiting(trailing: nil), .waiting(trailing: 104.3),
        .notice(CGSize(width: 260.7, height: 58.2)), .notice(CGSize(width: 4000, height: 20)),
        .notice(CGSize(width: 10, height: 10)),
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

    @Test func housingKindsFollowTheAuxiliaryAreas() {
        #expect(Self.island.kind == .island)
        #expect(Self.island.housing == HousingSpan(minX: 838.5, maxX: 897.5))
        #expect(Self.notch.kind == .notch)
        #expect(Self.notch.housing?.width == 185)
        #expect(Self.external.kind == .none)
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // A housing counts only if both areas exist and leave a gap between them.
        for (left, right) in [(nil, 600.0), (600.0, nil), (756.0, 756.0), (800.0, 800.0)] as [(Double?, Double?)] {
            let screen = ScreenTopology(frame: frame, safeAreaTop: 32, leftAreaWidth: left, rightAreaWidth: right,
                                        menuBarHeight: 24, scale: 2)
            #expect(screen.kind == .none)
        }
        // No band, no housing; and the boundary between island and notch is 110 pt.
        #expect(ScreenTopology(frame: frame, safeAreaTop: 0, leftAreaWidth: 700, rightAreaWidth: 700, menuBarHeight: 24,
                               scale: 2).kind == .none)
        #expect(ScreenTopology(frame: frame, safeAreaTop: 32, leftAreaWidth: 701.5, rightAreaWidth: 701,
                               menuBarHeight: 32, scale: 2).kind == .island)
        #expect(ScreenTopology(frame: frame, safeAreaTop: 32, leftAreaWidth: 701, rightAreaWidth: 701,
                               menuBarHeight: 32, scale: 2).kind == .notch)
    }

    /// On the 2026 MacBook Pro the island pill is a 32 pt black capsule centred on the housing, in the middle of its
    /// band; listening it grows sideways out of it, wave on the left and time on the right.
    @Test func theIslandMatchesTheHardware() throws {
        let rest = PillGeometry.layout(.rest, on: Self.island)
        #expect(rest.kind == .island)
        #expect(rest.body.frame == CGRect(x: 838.5, y: 4, width: 59, height: 32))
        #expect(rest.body.topRadius == 16 && rest.body.bottomRadius == 16)
        let listening = PillGeometry.layout(.listening(trailing: 30, cancel: false), on: Self.island)
        #expect(listening.body.frame.height == 32 && listening.body.frame.minY == 4)
        #expect(listening.body.frame.midX == 868)
        let leading = try #require(listening.leading), trailing = try #require(listening.trailing)
        #expect(Double(leading.width) == PillGeometry.waveWidth)
        #expect(Double(leading.maxX) == 838.5 - PillGeometry.housingGap)
        #expect(Double(trailing.minX) == 897.5 + PillGeometry.housingGap)
    }

    /// On a notched MacBook Pro the pill is one black shape flush with the top of the screen, as tall as the band,
    /// with rounded lower corners, so the notch appears to widen.
    @Test func theNotchWidens() {
        let rest = PillGeometry.layout(.rest, on: Self.notch)
        #expect(rest.body.frame == CGRect(x: 663.5, y: 0, width: 185, height: 32))
        #expect(rest.body.topRadius == 0 && rest.body.bottomRadius > 0)
        let listening = PillGeometry.layout(.listening(trailing: 30, cancel: true), on: Self.notch)
        #expect(listening.body.frame.minY == 0 && listening.body.frame.height == 32)
        #expect(listening.body.topRadius == 0)
        #expect(Double(listening.body.frame.width) > 185 + 2 * PillGeometry.waveWidth)
    }

    /// Without a housing the pill is the iPhone island itself: a 36 pt capsule 8 pt under the menu bar, centred.
    @Test func withoutAHousingThePillFloats() throws {
        for screen in [Self.external, Self.externalAt1x] {
            let listening = PillGeometry.layout(.listening(trailing: 30, cancel: false), on: screen)
            #expect(listening.kind == .none && listening.housing == nil)
            #expect(listening.body.frame.height == 36)
            #expect(Double(listening.body.frame.minY) == screen.menuBarHeight + 8)
            #expect(abs(Double(listening.body.frame.midX) - screen.width / 2) <= 1)
            #expect(listening.body.topRadius == 18 && listening.body.bottomRadius == 18)
            let leading = try #require(listening.leading), trailing = try #require(listening.trailing)
            #expect(leading.maxX < trailing.minX)
            let waiting = PillGeometry.layout(.waiting(trailing: nil), on: screen)
            #expect(waiting.trailing == nil && waiting.leading != nil)
        }
    }

    /// Every form on every screen: the body contains the housing; the wings are symmetric about it; nothing is laid
    /// out under it; content lies inside the body; everything stays on screen; every edge is on a whole pixel.
    @Test(arguments: Self.screens)
    func everyFormKeepsTheInvariants(screen: ScreenTopology) throws {
        for form in Self.forms {
            let layout = PillGeometry.layout(form, on: screen)
            let body = layout.body.frame
            let regions = [layout.leading, layout.trailing, layout.card, layout.cancel].compactMap { $0 }
            if let housing = layout.housing {
                #expect(Self.contains(body, housing), "\(form): the body leaves the housing out")
                for region in regions {
                    #expect(!region.intersects(housing), "\(form): content under the housing")
                }
                if let leading = layout.leading, let trailing = layout.trailing {
                    #expect(abs((housing.minX - leading.maxX) - (trailing.minX - housing.maxX)) < 1e-9)
                    #expect(abs(leading.width - trailing.width) < 1e-9, "\(form): lopsided wings")
                    #expect(abs((leading.minX - body.minX) - (body.maxX - trailing.maxX)) < 1e-9)
                }
            }
            for region in [layout.leading, layout.trailing, layout.card].compactMap({ $0 }) {
                #expect(Self.contains(body, region), "\(form): content outside the body")
            }
            for rect in [body] + regions {
                #expect(rect.minX >= 0 && Double(rect.maxX) <= screen.width, "\(form): off screen on \(screen)")
                #expect(rect.minY >= 0)
                #expect(Self.onPixels(rect, screen.scale), "\(form): \(rect) is between pixels at \(screen.scale)x")
            }
            if let housing = layout.housing, case .rest = form {
                #expect(body == housing, "the rest frame is not the housing's footprint")
            }
            if let cancel = layout.cancel {
                #expect(cancel.width == cancel.height)
                #expect(Double(cancel.minX - body.maxX) == PillGeometry.budGap)
                #expect(abs(cancel.midY - body.midY) <= 0.5)
            }
            if case .notice = form, layout.kind != .none, let card = layout.card {
                #expect(Double(card.minY) >= screen.safeAreaTop, "a notice is laid out in the band")
            }
        }
    }

    /// The listening forms on the same screen keep the body in one place, whatever the time's width or the bud, so the
    /// pill does not jitter as the seconds tick; only content wider than the wave widens it.
    @Test func listeningKeepsItsSize() {
        let a = PillGeometry.layout(.listening(trailing: 28, cancel: false), on: Self.island)
        let b = PillGeometry.layout(.listening(trailing: 41, cancel: true), on: Self.island)
        #expect(a.body == b.body)
        let wide = PillGeometry.layout(.waiting(trailing: 130), on: Self.island)
        #expect(wide.body.frame.width > a.body.frame.width)
    }

    /// The two hidden nudges move and resize only the island pill, within ±8 pt.
    @Test func theNudgesMoveTheIslandOnly() {
        let nudged = PillAdjustments(islandHeight: 4, islandOffset: -2)
        let rest = PillGeometry.layout(.rest, on: Self.island, adjustments: nudged)
        #expect(rest.body.frame == CGRect(x: 838.5, y: 0, width: 59, height: 36))
        let far = PillGeometry.layout(.rest, on: Self.island, adjustments: PillAdjustments(islandHeight: 100,
                                                                                            islandOffset: .nan))
        #expect(far.body.frame.height == 40)
        #expect(far.body.frame.minY == 0)
        for screen in [Self.notch, Self.external] {
            #expect(PillGeometry.layout(.listening(trailing: 30, cancel: false), on: screen, adjustments: nudged)
                == PillGeometry.layout(.listening(trailing: 30, cancel: false), on: screen))
        }
    }

    /// A suggestion's four actions, wrapping for a long app name, on every screen: every action lies in the card,
    /// below the band, clear of the housing, inside the screen's margins, on whole pixels.
    @Test(arguments: Self.screens)
    func fourActionsFitTheCardOnEveryScreen(screen: ScreenTopology) throws {
        for titles in [[126.0, 121, 77, 111], [262, 121, 77, 111]] {
            let notice = NoticeLayout(symbol: CGSize(width: 18, height: 18), text: CGSize(width: 260, height: 16),
                                      actions: titles.map { CGSize(width: $0, height: 26) },
                                      maxWidth: PillGeometry.maximumCardContent(on: screen), scale: screen.scale)
            let layout = PillGeometry.layout(.notice(notice.size), on: screen)
            let card = try #require(layout.card)
            #expect(notice.actions.count == 4)
            for action in notice.actions {
                let frame = action.offsetBy(dx: card.minX, dy: card.minY)
                #expect(Self.contains(card, frame))
                #expect(Self.contains(layout.body.frame, frame))
                if let housing = layout.housing { #expect(!frame.intersects(housing)) }
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
        #expect(crowded.actions.allSatisfy { $0.width > 0 && $0.maxX <= 300 })
        let none = NoticeLayout(symbol: CGSize(width: 16, height: 16), text: CGSize(width: 50, height: 16), actions: [],
                                maxWidth: 400, scale: 1)
        #expect(none.size.height == 16)
        let odd = NoticeLayout(symbol: CGSize(width: Double.nan, height: -1), text: CGSize(width: Double.infinity,
                                                                                            height: 16),
                               actions: [], maxWidth: .nan, scale: 0)
        #expect(odd.size.width == 0)
    }
}
