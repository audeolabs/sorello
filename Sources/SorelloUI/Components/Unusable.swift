import SwiftUI

extension View {
    /// Draws the view at `ThemeColors.unusableAlpha` while it cannot be used (ARCHITECTURE.md, section 8). Sorello dims
    /// its controls itself rather than leaving it to the system, which dims some controls for an app that records one
    /// SDK and not for an app that records another.
    func dimmedWhenUnusable() -> some View {
        modifier(UnusableDimming())
    }
}

private struct UnusableDimming: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : ThemeColors.unusableAlpha)
    }
}
