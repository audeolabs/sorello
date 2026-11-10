import AppKit
import CoreText
import DesignCore

/// The pill's outline as a path, in the screen's points (top left, y down): the body, and the cancel bud and the neck
/// joining it while it buds out or is taken back, as one shape, so the edge drawn around it is one line with no seam.
enum PillPath {
    /// The outline, cut off at `ceiling`, the foot of the top band: a bud taken back into a body going back up is
    /// rounder than the rest it goes into, and nothing may be drawn in the band.
    static func outline(_ body: PillBody, bud: CancelBud.Frame?, budY: Double, ceiling: Double) -> CGPath {
        let whole = joined(body, bud: bud, budY: budY)
        let box = whole.boundingBoxOfPath
        guard Double(box.minY) < ceiling, !box.isEmpty else { return whole }
        let below = CGRect(x: box.minX - 1, y: ceiling, width: box.width + 2,
                           height: max(Double(box.maxY) - ceiling, 0))
        return whole.intersection(CGPath(rect: below, transform: nil))
    }

    /// The body, and the bud and its neck, as one shape.
    private static func joined(_ body: PillBody, bud: CancelBud.Frame?, budY: Double) -> CGPath {
        let shape = rounded(body)
        guard let bud else { return shape }
        let circle = CGPath(ellipseIn: CGRect(x: bud.centre - bud.radius, y: budY - bud.radius, width: 2 * bud.radius,
                                              height: 2 * bud.radius), transform: nil)
        var joined = shape.union(circle)
        if let neck = bud.neck {
            func point(_ p: CancelBud.Point) -> CGPoint { CGPoint(x: p.x, y: p.y) }
            let bridge = CGMutablePath()
            bridge.move(to: point(neck.p1))
            bridge.addCurve(to: point(neck.p3), control1: point(neck.h1), control2: point(neck.h3))
            bridge.addLine(to: point(neck.p4))
            bridge.addCurve(to: point(neck.p2), control1: point(neck.h4), control2: point(neck.h2))
            bridge.closeSubpath()
            joined = joined.union(bridge)
        }
        return joined
    }

    /// A rectangle with its top corners rounded by one radius and its bottom corners by another.
    static func rounded(_ body: PillBody) -> CGPath {
        let f = body.frame, (top, bottom) = body.drawnRadii
        let path = CGMutablePath()
        guard f.width > 0, f.height > 0 else { return path }
        path.move(to: CGPoint(x: f.minX + top, y: f.minY))
        path.addLine(to: CGPoint(x: f.maxX - top, y: f.minY))
        path.addArc(tangent1End: CGPoint(x: f.maxX, y: f.minY), tangent2End: CGPoint(x: f.maxX, y: f.minY + top),
                    radius: top)
        path.addLine(to: CGPoint(x: f.maxX, y: f.maxY - bottom))
        path.addArc(tangent1End: CGPoint(x: f.maxX, y: f.maxY), tangent2End: CGPoint(x: f.maxX - bottom, y: f.maxY),
                    radius: bottom)
        path.addLine(to: CGPoint(x: f.minX + bottom, y: f.maxY))
        path.addArc(tangent1End: CGPoint(x: f.minX, y: f.maxY), tangent2End: CGPoint(x: f.minX, y: f.maxY - bottom),
                    radius: bottom)
        path.addLine(to: CGPoint(x: f.minX, y: f.minY + top))
        path.addArc(tangent1End: CGPoint(x: f.minX, y: f.minY), tangent2End: CGPoint(x: f.minX + top, y: f.minY),
                    radius: top)
        path.closeSubpath()
        return path
    }
}

/// One line of text or a symbol rendered to an image for a layer, so the pill controls exactly where the baseline
/// lands (on a whole pixel, the line optically centred on the pill's middle) and how a line too long is truncated.
struct PillImage {
    var image: CGImage
    /// In points.
    var size: CGSize
    /// The baseline's distance from the image's top, in points; zero for a symbol.
    var ascent: CGFloat

    /// `text` in `font` and `color`, truncated with an ellipsis to `maxWidth` points.
    static func text(_ text: String, font: NSFont, color: NSColor, maxWidth: CGFloat, scale: CGFloat) -> PillImage? {
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let full = CTLineCreateWithAttributedString(attributed)
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}",
                                                                           attributes: [.font: font,
                                                                                        .foregroundColor: color]))
        let line = CTLineCreateTruncatedLine(full, Double(max(maxWidth, 1)), .end, ellipsis) ?? full
        let width = min(ceil(CTLineGetTypographicBounds(line, nil, nil, nil) * scale) / scale, max(maxWidth, 1))
        let ascent = ceil(font.ascender * scale) / scale, descent = ceil(-font.descender * scale) / scale
        let size = CGSize(width: width, height: ascent + descent)
        return draw(size: size, scale: scale) { context in
            context.textPosition = CGPoint(x: 0, y: descent)
            CTLineDraw(line, context)
        }.map { PillImage(image: $0, size: size, ascent: ascent) }
    }

    /// The SF Symbol `name` at `pointSize`, tinted `color`.
    static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor,
                       scale: CGFloat) -> PillImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let size = CGSize(width: ceil(symbol.size.width * scale) / scale, height: ceil(symbol.size.height * scale) / scale)
        return draw(size: size, scale: scale) { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            symbol.draw(in: CGRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
        }.map { PillImage(image: $0, size: size, ascent: 0) }
    }

    private static func draw(size: CGSize, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setShouldSmoothFonts(false)
        context.textMatrix = .identity
        body(context)
        return context.makeImage()
    }
}

/// A pool of dot layers in one parent. A frame writes only what changed since the last: each dot is a small
/// layer with a corner radius, so the render server composites them and nothing is redrawn.
final class DotLayers {
    let parent = CALayer()
    private var layers: [CALayer] = []
    private var shown: [DotWave.Dot?] = []
    private var color: CGColor?

    init() {
        parent.actions = ["sublayers": NSNull()]
    }

    /// The dot layers showing now.
    var showing: [CALayer] { zip(layers, shown).filter { $0.1 != nil }.map(\.0) }

    /// Shows `dots`, given in the parent's coordinates, in `color`; the brightness is each dot's opacity.
    func show(_ dots: [DotWave.Dot], color: CGColor) {
        let recolor = color != self.color
        self.color = color
        while layers.count < dots.count {
            let layer = CALayer()
            layer.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(), "opacity": NSNull(),
                             "backgroundColor": NSNull(), "hidden": NSNull()]
            layer.backgroundColor = color
            parent.addSublayer(layer)
            layers.append(layer)
            shown.append(nil)
        }
        for (index, layer) in layers.enumerated() {
            guard index < dots.count else {
                if shown[index] != nil {
                    layer.isHidden = true
                    shown[index] = nil
                }
                continue
            }
            let dot = dots[index], last = shown[index]
            // What the layer holds now: a change too small to see is not written, nor remembered as written.
            var written = last ?? dot
            if last == nil { layer.isHidden = false }
            if recolor { layer.backgroundColor = color }
            if last == nil || abs(written.radius - dot.radius) > 0.002 {
                layer.bounds = CGRect(x: 0, y: 0, width: 2 * dot.radius, height: 2 * dot.radius)
                layer.cornerRadius = dot.radius
                written.radius = dot.radius
            }
            if last == nil || written.x != dot.x || written.y != dot.y {
                layer.position = CGPoint(x: dot.x, y: dot.y)
                written.x = dot.x
                written.y = dot.y
            }
            if last == nil || abs(written.brightness - dot.brightness) > 0.002 {
                layer.opacity = Float(min(max(dot.brightness, 0), 1))
                written.brightness = dot.brightness
            }
            shown[index] = written
        }
    }
}
