import AppKit
import DesignCore

/// The window chrome the screens are drawn for. The app layer creates the windows and calls `apply` on each, so
/// every window matches: a transparent title bar over full-size content, the screen colour behind it, the dark
/// appearance whatever the system's, and a minimum size at which nothing is clipped.
public enum WindowChrome {
    /// The kinds of window Sorello opens.
    public enum Kind: Sendable {
        /// The main window: sidebar and screens.
        case main
        /// Setup, shown on first launch.
        case setup

        /// The smallest the window may be.
        public var minimumSize: CGSize {
            switch self {
            case .main: CGSize(width: 780, height: 520)
            case .setup: CGSize(width: 600, height: 620)
            }
        }

        /// The size the window opens at.
        public var defaultSize: CGSize {
            switch self {
            case .main: CGSize(width: 880, height: 640)
            case .setup: CGSize(width: 600, height: 620)
            }
        }
    }

    /// Gives `window` the chrome its screens are drawn for. Setup cannot be resized and can be dragged by its
    /// background, as a setup assistant can.
    public static func apply(to window: NSWindow, kind: Kind) {
        window.styleMask.insert([.titled, .closable, .miniaturizable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(Palette.screen)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentMinSize = kind.minimumSize
        switch kind {
        case .main:
            window.styleMask.insert(.resizable)
            window.isMovableByWindowBackground = false
            window.tabbingMode = .disallowed
        case .setup:
            window.styleMask.remove(.resizable)
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        }
    }
}
