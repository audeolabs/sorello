import AppKit
import Foundation
@testable import MacPlatform
import QuartzCore
import Testing

/// ARCHITECTURE.md, section 6: the drag card's surface is Liquid Glass on macOS 26 and later and the system's blurred
/// material before that, with the same shape, frost and shadows. Section 11: the older surface can be forced, so it is
/// tested on the Macs Sorello is built on.
@MainActor
@Suite("Drag card surface")
struct CardSurfaceTests {
    private static let size = NSSize(width: 532, height: 95)

    private func surface(forcesOlderSurface: Bool) -> PermissionPanel.CardSurface {
        PermissionPanel.CardSurface(content: NSView(), size: Self.size, frostColor: .black,
                                    forcesOlderSurface: forcesOlderSurface)
    }

    @Test("The card is Liquid Glass from macOS 26, the blurred material before")
    func materialFollowsTheSystem() throws {
        let hasGlass = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        let card = surface(forcesOlderSurface: false)
        #expect(card.backdrop.material == (hasGlass ? .liquidGlass : .blurredMaterial))
        let drawnBy: AnyClass = hasGlass ? try #require(NSClassFromString("NSGlassEffectView")) : NSVisualEffectView.self
        #expect(card.backdrop.view.isKind(of: drawnBy))
        #expect(card.backdrop.view.superview === card, "the material sits directly in the surface, under the frost")
    }

    @Test("Forced, the card has the blurred material, blurring what is behind it whichever app is in front")
    func olderSurface() throws {
        let card = surface(forcesOlderSurface: true)
        #expect(card.backdrop.material == .blurredMaterial)
        let blur = try #require(card.backdrop.view as? NSVisualEffectView)
        #expect(blur.blendingMode == .behindWindow)
        // System Settings is in front while the card is up, never Sorello; an inactive material is drawn flat.
        #expect(blur.state == .active)
        #expect(blur.superview === card)
    }

    @Test("Either material fills the card and is cut to its rounded corners, at every size of the flight",
          arguments: [false, true])
    func shape(forcesOlderSurface: Bool) throws {
        let card = surface(forcesOlderSurface: forcesOlderSurface)
        // Docked; mid-flight, widening from the button; leaving the button, a capsule.
        let flight: [(NSSize, CGFloat)] = [(Self.size, 18), (NSSize(width: 300, height: 60), 16),
                                           (NSSize(width: 120, height: 30), 15)]
        for (size, radius) in flight {
            card.apply(size: size, radius: radius, lift: 0)
            let view = card.backdrop.view
            #expect(view.frame == NSRect(origin: .zero, size: size))
            #expect(card.clip.layer?.cornerRadius == radius)
            #expect(card.clip.layer?.cornerCurve == .continuous)
            switch card.backdrop.material {
            case .liquidGlass:
                #expect((view.value(forKey: "cornerRadius") as? CGFloat) == radius)
            case .blurredMaterial:
                let mask = try #require((view as? NSVisualEffectView)?.maskImage)
                #expect(mask.size == size)
                let drawn = try coverage(size: size) { _ in mask.draw(in: NSRect(origin: .zero, size: size)) }
                let clip = CALayer()
                clip.frame = CGRect(origin: .zero, size: size)
                clip.backgroundColor = NSColor.black.cgColor
                clip.cornerRadius = radius
                clip.cornerCurve = .continuous
                let clipped = try coverage(size: size) { clip.render(in: $0) }
                // The blur covers what the frost and content cover. A different outline strays by far more than 8/255
                // somewhere along a corner (a capsule drawn as SwiftUI rounds it, by 76).
                let worst = zip(drawn, clipped).map { abs(Int($0) - Int($1)) }.max() ?? 0
                #expect(worst <= 8, "size \(size), radius \(radius): the mask strays \(worst)/255 from the clip")
                #expect(drawn.first == 0, "a corner is cut")
                #expect(drawn[Int(size.height) * Int(size.width * 2) + Int(size.width)] == 255, "the middle is covered")
            }
        }
    }

    @Test("Frost, clipping and shadows are the same on either material")
    func sameApartFromTheMaterial() {
        let glass = surface(forcesOlderSurface: false)
        let blurred = surface(forcesOlderSurface: true)
        for lift in [0.0, 0.6, 1.0] {
            for card in [glass, blurred] { card.apply(size: Self.size, radius: 18, lift: lift) }
            #expect(look(of: glass) == look(of: blurred), "lift \(lift)")
        }
    }

    /// What a surface draws besides its material: the frost's colour, the clip's shape, and every shadow.
    private func look(of card: PermissionPanel.CardSurface) -> [String] {
        card.frost.updateLayer()
        let shadows = (card.layer?.sublayers ?? []).filter { $0.shadowOpacity > 0 }.map {
            "shadow \($0.shadowOpacity) \($0.shadowRadius) \($0.shadowOffset) \($0.shadowPath?.boundingBox ?? .null)"
        }
        return ["frost \(card.frost.layer?.backgroundColor?.components ?? [])",
                "clip \(card.clip.frame) \(card.clip.layer?.cornerRadius ?? -1) \(card.clip.layer?.masksToBounds ?? false)"]
            + shadows
    }

    /// How much of each pixel `draw` covers, 0 to 255, at two pixels per point, row by row.
    private func coverage(size: NSSize, draw: (CGContext) -> Void) throws -> [UInt8] {
        let width = Int(size.width * 2), height = Int(size.height * 2)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(context.data)
        let pixels = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }
}
