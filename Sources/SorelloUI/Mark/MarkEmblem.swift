import DesignCore
import SwiftUI

/// The mark at rest on the island, for setup's welcome and the About screen: the near-black capsule with its hairline,
/// and in it the Sorello mark, its aurora dot glowing as it does on the app icon. Decorative.
public struct MarkEmblem: View {
    private let scale: CGFloat

    /// The emblem at `scale` times its natural size (40 points tall).
    public init(scale: CGFloat = 1) {
        self.scale = scale
    }

    /// The mark's box inside the capsule, in points at scale 1.
    private static let markSize = CGSize(width: 66, height: 16)

    public var body: some View {
        let size = CGSize(width: Self.markSize.width * scale, height: Self.markSize.height * scale)
        let accent = SorelloMark.fitted(x: 0, y: 0, width: Double(size.width), height: Double(size.height),
                                        weight: 1.05).accent
        ZStack(alignment: .topLeading) {
            Circle()
                .fill(RadialGradient(colors: [Color(Palette.aurora).opacity(0.38), .clear], center: .center,
                                     startRadius: 0, endRadius: 15 * scale))
                .frame(width: 30 * scale, height: 30 * scale)
                .offset(x: CGFloat(accent.x) - 15 * scale, y: CGFloat(accent.y) - 15 * scale)
            SorelloMarkView(weight: 1.05)
                .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .padding(.horizontal, 20 * scale)
        .frame(height: 40 * scale)
        .islandSurface()
        .accessibilityHidden(true)
    }
}
