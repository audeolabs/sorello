import DesignCore
import SwiftUI

/// The surfaces and focus ring every window's controls are drawn with.
public extension View {
    /// The island's surface, as the pill and the iPhone app's buttons have it: the near-black pill colour with a
    /// grey hairline, a full point wide with Increase Contrast.
    func islandSurface<S: InsettableShape>(_ shape: S) -> some View {
        modifier(IslandSurface(shape: shape))
    }

    /// The island's surface as a capsule.
    func islandSurface() -> some View { islandSurface(Pill()) }

    /// A card: the card colour behind rows, with rounded corners.
    func cardSurface(radius: CGFloat = Metrics.cardRadius) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Sorello's keyboard focus ring: a white ring just outside `shape`, drawn only while `isFocused`. It replaces
    /// the system's accent ring, which would put colour on a control that shows no state.
    func focusRing<S: InsettableShape>(_ shape: S, isFocused: Bool) -> some View {
        overlay {
            shape.inset(by: -3)
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
    }
}

private struct IslandSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Theme.pill, in: shape)
            .overlay(shape.strokeBorder(Theme.edge, lineWidth: Palette.edgeWidth(highContrast: contrast == .increased)))
    }
}

/// A capsule drawn as a rectangle with fully rounded ends. SwiftUI's `Capsule` path leaves short vertical
/// hairlines at the ends of a thin stroke; this shape does not, and is otherwise the same.
nonisolated public struct Pill: InsettableShape {
    private var inset: CGFloat = 0

    /// A pill filling its frame.
    public init() {}

    /// The outline: `rect`, inset, with ends rounded by half its shorter side.
    public func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        return RoundedRectangle(cornerRadius: min(rect.width, rect.height) / 2, style: .circular).path(in: rect)
    }

    /// The same pill, `amount` smaller on every side.
    public func inset(by amount: CGFloat) -> Pill {
        var shape = self
        shape.inset += amount
        return shape
    }
}
