import DesignCore
import SwiftUI
import Testing

/// ARCHITECTURE.md, section 8, "The mark": the iPhone app's icon is the same picture drawn to the edges, because iOS
/// cuts an icon's corners itself.
@MainActor
struct IPhoneIconTests {
    /// iOS cuts the icon to a square with continuous corners, the shape SwiftUI draws as a continuous rounded
    /// rectangle. Every star lies well inside it, by the margin the Mac's stars keep from their field's edge under the
    /// same scaling, so none is clipped on the Home Screen.
    @Test func theStarsLieWellInsideTheShapeIOSCutsTheIconTo() {
        let canvas = AppIconGeometry.canvas
        let shape = RoundedRectangle(cornerRadius: AppIconGeometry.iOSCornerRadius, style: .continuous)
            .path(in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
        let margin = 48 * AppIconGeometry.iPhone.fieldSide / AppIconGeometry.mac.fieldSide
        for star in AppIconGeometry.iPhone.stars {
            let reach = star.radius + margin
            let outside = (0 ..< 720).map { Double($0) / 720 * 2 * .pi }.filter { angle in
                !shape.contains(CGPoint(x: star.x + reach * cos(angle), y: star.y + reach * sin(angle)))
            }
            #expect(outside.isEmpty, "\(star) is less than \(margin) units inside the shape iOS cuts the icon to")
        }
    }
}
