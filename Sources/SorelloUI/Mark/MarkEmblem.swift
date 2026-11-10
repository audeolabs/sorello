import DesignCore
import SwiftUI

/// The mark at rest on the island, for setup's welcome and the About screen: the near-black capsule with its hairline,
/// and in it the Sorello mark, its aurora dot glowing as it does on the app icon. Decorative.
///
/// The capsule, the glow and the dots are drawn in one space, the capsule's own (ARCHITECTURE.md, section 8, "The
/// mark"): the mark's ink is centred in the capsule both ways, and the glow is centred on the aurora dot wherever the
/// mark puts it.
public struct MarkEmblem: View {
    private let scale: CGFloat

    /// The emblem at `scale` times its natural size (40 points tall).
    public init(scale: CGFloat = 1) {
        self.scale = scale
    }

    /// The capsule, in points at scale 1: the island's height, and the mark's width with 20 points each side.
    private static let capsule = CGSize(width: 106, height: 40)
    /// The box the mark's ink fills, in points at scale 1. The mark is wider than this box is tall, so its ink spans
    /// the width and is centred in the height.
    private static let markBox = CGSize(width: 66, height: 16)
    /// How far the aurora dot's glow reaches from its centre, in points at scale 1.
    private static let glowRadius: CGFloat = 15
    /// The mark's dot weight here, a little heavier than its own at this small size.
    private static let weight = 1.05

    public var body: some View {
        let scale = self.scale
        Canvas { context, size in
            let box = CGSize(width: Self.markBox.width * scale, height: Self.markBox.height * scale)
            let mark = SorelloMark.fitted(x: Double(size.width - box.width) / 2, y: Double(size.height - box.height) / 2,
                                          width: Double(box.width), height: Double(box.height), weight: Self.weight)
            let centre = CGPoint(x: mark.accent.x, y: mark.accent.y), radius = Self.glowRadius * scale
            context.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius,
                                                height: 2 * radius)),
                         with: .radialGradient(Gradient(colors: [Color(Palette.aurora).opacity(0.38), .clear]),
                                               center: centre, startRadius: 0, endRadius: radius))
            SorelloMarkView.draw(mark, in: context)
        }
        .frame(width: Self.capsule.width * scale, height: Self.capsule.height * scale)
        .islandSurface()
        .accessibilityHidden(true)
    }
}
