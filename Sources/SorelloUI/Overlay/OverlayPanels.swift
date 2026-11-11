import AppKit
import DesignCore

/// One of the overlay's two windows (ARCHITECTURE.md, section 8, "The pill"): borderless and non-activating, never
/// key or main, on every Space and over full-screen apps, at the status-bar level. The drawing panel ignores the
/// mouse entirely; the controls panel, one level above it, takes clicks on the pill's controls only.
final class OverlayPanel: NSPanel {
    init(interactive: Bool) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = interactive ? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1) : .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = !interactive
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovable = false
        isExcludedFromWindowsMenu = true
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The pill's controls, each in a small panel of its own exactly its size, so the gaps between them (the space between
/// the pill and its cancel bud, the corners of a card) never swallow a click meant for what is underneath. A panel is
/// on the screen only while its control is.
final class ControlPanels {
    /// A control was held down (its kind) or let go (nil): the pill dims it.
    var onPress: (PillControl.Kind?) -> Void = { _ in }
    /// A control was clicked, or pressed through VoiceOver.
    var onActivate: (PillControl.Kind) -> Void = { _ in }

    private var panels: [(panel: OverlayPanel, target: ControlTarget)] = []
    private var shown = 0

    /// The frames, in global coordinates, of the panels on the screen.
    var frames: [CGRect] { panels.prefix(shown).map(\.panel.frame) }

    /// Shows `controls`, placing each at `global(control.frame)`.
    func show(_ controls: [PillControl], global: (CGRect) -> CGRect) {
        while panels.count < controls.count {
            let panel = OverlayPanel(interactive: true), target = ControlTarget()
            target.onPress = { [weak self] kind in self?.onPress(kind) }
            target.onActivate = { [weak self] kind in self?.onActivate(kind) }
            panel.contentView = target
            panels.append((panel, target))
        }
        for (index, entry) in panels.enumerated() {
            guard index < controls.count else {
                entry.target.control = nil
                entry.panel.orderOut(nil)
                continue
            }
            entry.target.control = controls[index]
            entry.panel.setFrame(global(controls[index].frame), display: false)
            entry.panel.orderFrontRegardless()
        }
        shown = controls.count
    }

    func hide() {
        show([], global: { $0 })
    }
}

/// One clickable control of the pill: a button to VoiceOver, with the pill's label for it. A click acts on the first
/// mouse-down's release inside it, so it works although its window never becomes key.
final class ControlTarget: NSView {
    /// The control this target stands for; nil while its panel is off the screen.
    var control: PillControl? {
        didSet {
            setAccessibilityLabel(control?.label)
            // A press belongs to the control it began on: if this target now stands for another, or for none, the
            // press is abandoned.
            if control?.kind != oldValue?.kind, tracking {
                tracking = false
                onPress(nil)
            }
        }
    }
    var onPress: (PillControl.Kind?) -> Void = { _ in }
    var onActivate: (PillControl.Kind) -> Void = { _ in }
    private var tracking = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let control else { return }
        tracking = true
        onPress(control.kind)
    }

    override func mouseDragged(with event: NSEvent) {
        guard tracking, let control else { return }
        onPress(contains(event) ? control.kind : nil)
    }

    override func mouseUp(with event: NSEvent) {
        guard tracking, let control else { return }
        tracking = false
        onPress(nil)
        if contains(event) { onActivate(control.kind) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let control else { return false }
        onActivate(control.kind)
        return true
    }

    private func contains(_ event: NSEvent) -> Bool {
        bounds.contains(convert(event.locationInWindow, from: nil))
    }
}

extension ScreenTopology {
    /// What `screen` reports about its top: the housing's band and the areas beside it, the menu bar, the scale.
    @MainActor
    init(_ screen: NSScreen) {
        let menuBar = Double(screen.frame.maxY - screen.visibleFrame.maxY)
        // With the menu bar hidden the visible frame reaches the top; the pill still keeps clear of where it shows.
        let shown = menuBar > 0 ? menuBar : max(Double(screen.safeAreaInsets.top), Double(NSStatusBar.system.thickness))
        self.init(frame: screen.frame, safeAreaTop: Double(screen.safeAreaInsets.top),
                  leftAreaWidth: screen.auxiliaryTopLeftArea.map { Double($0.width) },
                  rightAreaWidth: screen.auxiliaryTopRightArea.map { Double($0.width) },
                  menuBarHeight: shown, scale: Double(screen.backingScaleFactor))
    }
}

extension NSScreen {
    /// The display's number, which stays the same while it is connected.
    var displayNumber: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
