import SwiftUI
import UIKit

/// `BrandPalette` as UIKit and SwiftUI colours (ARCHITECTURE.md, "Keyboard look").
extension BrandPalette {
    init(_ traits: UITraitCollection) {
        self.init(dark: traits.userInterfaceStyle == .dark, highContrast: traits.accessibilityContrast == .high)
    }

    init(colorScheme: ColorScheme, contrast: ColorSchemeContrast) {
        self.init(dark: colorScheme == .dark, highContrast: contrast == .increased)
    }

    /// A colour that follows light and dark mode and Increase Contrast without re-rendering.
    static func dynamic(_ pick: @escaping @Sendable (BrandPalette) -> RGB) -> UIColor {
        UIColor { UIColor(pick(BrandPalette($0))) }
    }
}

extension UIColor {
    convenience init(_ rgb: BrandPalette.RGB, alpha: CGFloat = 1) {
        self.init(red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: alpha)
    }
}

extension Color {
    init(_ rgb: BrandPalette.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// The ring mark (`RingMark`) as a SwiftUI shape: its seven white dots, or with `state` its state dot. Fill each.
struct RingMarkShape: Shape {
    var state = false

    func path(in rect: CGRect) -> Path {
        let mark = RingMark.fitted(in: KeyRect(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width),
                                               height: Double(rect.height)))
        var path = Path()
        func add(_ dot: RingMark.Point, _ radius: Double) {
            path.addEllipse(in: CGRect(x: dot.x - radius, y: dot.y - radius, width: 2 * radius, height: 2 * radius))
        }
        if state {
            add(mark.stateDot, mark.stateRadius)
        } else {
            for dot in mark.whiteDots { add(dot, mark.whiteRadius) }
        }
        return path
    }

    /// Where the state dot's centre is in a square box, as a unit point (the anchor to scale the dot about).
    static var stateAnchor: UnitPoint {
        let mark = RingMark.fitted(in: KeyRect(x: 0, y: 0, width: 1, height: 1))
        return UnitPoint(x: mark.stateDot.x, y: mark.stateDot.y)
    }
}
