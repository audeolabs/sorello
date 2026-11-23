import AppKit
import SwiftUI

// Calls macOS 13 lacks, each with the older call that answers for it there (ARCHITECTURE.md, section 15). In the
// usual build each of these is the newer call and nothing else, so a view is built as it was.

extension Text {
    /// The text in one colour. Text takes `foregroundStyle` from macOS 14, and `foregroundColor` before.
    public func inked(_ color: Color) -> Text {
        #if SORELLO_LEGACY
        if #available(macOS 14, *) { return foregroundStyle(color) }
        return foregroundColor(color)
        #else
        foregroundStyle(color)
        #endif
    }
}

extension View {
    /// Hides the focus ring the system draws, on a control that draws its own. Before macOS 14 the system's ring
    /// cannot be hidden, so the control shows both.
    @ViewBuilder
    public func systemFocusRingHidden() -> some View {
        #if SORELLO_LEGACY
        if #available(macOS 14, *) { focusEffectDisabled() } else { self }
        #else
        focusEffectDisabled()
        #endif
    }

    /// One symbol replaces another as symbols do. Before macOS 14 the two cross-fade.
    @ViewBuilder
    public func symbolReplaceTransition() -> some View {
        #if SORELLO_LEGACY
        if #available(macOS 14, *) { contentTransition(.symbolEffect(.replace)) } else { contentTransition(.opacity) }
        #else
        contentTransition(.symbolEffect(.replace))
        #endif
    }

    /// A scroll view that bounces only when its content is longer than it. Before macOS 13.3 it bounces either way.
    @ViewBuilder
    public func bouncesOnlyWhenScrollable() -> some View {
        #if SORELLO_LEGACY
        if #available(macOS 13.3, *) { scrollBounceBehavior(.basedOnSize) } else { self }
        #else
        scrollBounceBehavior(.basedOnSize)
        #endif
    }
}

extension NSApplication {
    /// Asks the system to make this app the active one. From macOS 14 that is a request the system may refuse;
    /// before, the app takes the front.
    public func comeForward() {
        #if SORELLO_LEGACY
        if #available(macOS 14, *) { activate() } else { activate(ignoringOtherApps: true) }
        #else
        activate()
        #endif
    }
}
