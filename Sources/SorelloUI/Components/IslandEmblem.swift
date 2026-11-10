import SwiftUI

/// A still picture of the island at rest, for setup's welcome and the About screen: the near-black capsule with
/// its hairline, a row of white dots rising toward the aurora dot. Decorative.
public struct IslandEmblem: View {
    private let scale: CGFloat

    public init(scale: CGFloat = 1) {
        self.scale = scale
    }

    /// The dots' radii, left to right, as a voice settling.
    private static let radii: [CGFloat] = [1.4, 1.6, 1.9, 2.3, 2.1, 2.6, 3.0, 2.7, 3.2]

    public var body: some View {
        HStack(spacing: 6.2 * scale - 3) {
            ForEach(Array(Self.radii.enumerated()), id: \.offset) { index, radius in
                Circle()
                    .fill(Color.white.opacity(0.45 + 0.55 * Double(index) / Double(Self.radii.count - 1)))
                    .frame(width: 2 * radius * scale, height: 2 * radius * scale)
            }
            Circle()
                .fill(Theme.aurora)
                .frame(width: 10 * scale, height: 10 * scale)
                .shadow(color: Theme.aurora.opacity(0.55), radius: 6 * scale)
                .padding(.leading, 4 * scale)
        }
        .padding(.horizontal, 18 * scale)
        .frame(height: 40 * scale)
        .islandSurface()
        .accessibilityHidden(true)
    }
}
