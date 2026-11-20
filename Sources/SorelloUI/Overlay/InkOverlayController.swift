import AppKit
import DesignCore

/// What the ink overlay draws over a display while a screen note records (ARCHITECTURE.md, section 14, "Marks"). Places
/// are points of the display from its top left; times are on the clock the overlay was given.
public struct InkScene: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public var points: [CGPoint]
        /// When it ended; nil while it is being drawn.
        public var endedAt: TimeInterval?

        public init(points: [CGPoint], endedAt: TimeInterval?) {
            self.points = points
            self.endedAt = endedAt
        }
    }

    public struct Pin: Equatable, Sendable {
        public var number: Int
        public var point: CGPoint
        public var droppedAt: TimeInterval

        public init(number: Int, point: CGPoint, droppedAt: TimeInterval) {
            self.number = number
            self.point = point
            self.droppedAt = droppedAt
        }
    }

    public var lines: [Line]
    public var pins: [Pin]

    public init(lines: [Line] = [], pins: [Pin] = []) {
        self.lines = lines
        self.pins = pins
    }
}

/// A finger on the ink overlay of a touch screen (ARCHITECTURE.md, section 14, "Marks", "Touch"), in points of the
/// display from its top left, at times on the overlay's clock.
public enum InkTouch: Equatable, Sendable {
    case began(CGPoint, time: TimeInterval)
    case moved(CGPoint, time: TimeInterval)
    case ended(CGPoint, time: TimeInterval)
}

/// A transparent window over one display that draws a note's ink and pins. It never takes the mouse or the keyboard,
/// is never shared or recorded, and shows on every Space. A stroke fades 1.5 s after it ends; a pin shows as a ring
/// that grows and fades. On a touch screen a second window under it takes fingers, everywhere but around the pointer,
/// and reports them.
@MainActor
public final class InkOverlayController {
    /// The radius, in points, of the clear circle around the pointer through which it still reaches the apps.
    public static let pointerClearance: CGFloat = 60
    /// The fill that catches a finger: the faintest a touch lands on, which cannot be seen.
    static let catcherAlpha: CGFloat = 1.0 / 255

    /// How long an ended stroke stays before it fades, and how long the fade takes.
    public static let linger: TimeInterval = 1.5
    public static let fade: TimeInterval = 0.5
    /// How long a pin's ring lasts.
    public static let pulse: TimeInterval = 0.8

    private var panel: NSPanel?
    private var view: InkView?
    /// On a touch screen, the window that takes the fingers.
    private var catcherPanel: NSPanel?
    private var catcher: TouchCatcher?
    private var timer: Timer?
    private var wasAnimating = false
    private let clock: () -> TimeInterval

    /// `clock` is the same as the scene's times.
    public init(clock: @escaping () -> TimeInterval) {
        self.clock = clock
    }

    /// Puts the overlay over `frame`, a display's frame in the global AppKit space. With `touch`, a second window takes
    /// the fingers on that display, except in a circle around the pointer, and reports each to `touch`.
    public func show(on frame: CGRect, touch: (@MainActor (InkTouch) -> Void)? = nil) {
        hide()
        let panel = Self.inkPanel(over: frame)
        let view = InkView(frame: CGRect(origin: .zero, size: frame.size), clock: clock)
        panel.contentView = view
        panel.setFrame(frame, display: false)
        if let touch {
            let clock = self.clock
            let catcherPanel = Self.catcherPanel(over: frame)
            let catcher = TouchCatcher(frame: CGRect(origin: .zero, size: frame.size)) { recognizer, catcher in
                // The catcher's places are from its bottom left; a touch is reported from the display's top left.
                let place = recognizer.location(in: catcher)
                let point = CGPoint(x: place.x, y: catcher.bounds.height - place.y), time = clock()
                switch recognizer.state {
                case .began: touch(.began(point, time: time))
                case .changed: touch(.moved(point, time: time))
                case .ended, .cancelled, .failed: touch(.ended(point, time: time))
                default: break
                }
            }
            catcherPanel.contentView = catcher
            catcherPanel.setFrame(frame, display: false)
            catcherPanel.orderFrontRegardless()
            self.catcherPanel = catcherPanel
            self.catcher = catcher
        }
        panel.orderFrontRegardless()
        self.panel = panel
        self.view = view
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The window that draws the ink over `frame`: clear, never shared or recorded, on every Space, taking nothing, and
    /// over everything on the display, an open menu included.
    static func inkPanel(over frame: CGRect) -> NSPanel {
        let panel = clearPanel(over: frame)
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        return panel
    }

    /// The window that takes the fingers on a touch screen. It is left to the system's rule that a click or touch on a
    /// clear pixel goes through to what is underneath: the catcher's faint fill takes them, and its hole around the
    /// pointer lets the pointer through. Just under the pill's controls (OverlayPanel), so a finger can press them,
    /// and under menus.
    static func catcherPanel(over frame: CGRect) -> NSPanel {
        let panel = clearPanel(over: frame)
        panel.level = .statusBar
        return panel
    }

    private static func clearPanel(over frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        return panel
    }

    public func update(_ scene: InkScene) {
        guard let view, view.scene != scene else { return }
        view.scene = scene
        view.needsDisplay = true
    }

    public func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        view = nil
        catcherPanel?.orderOut(nil)
        catcherPanel = nil
        catcher = nil
    }

    /// Redraws while something fades or pulses, and once more as the last of it ends, so nothing is left half faded.
    /// Keeps the catcher's hole where the pointer is.
    private func tick() {
        if let catcher, let catcherPanel {
            catcher.clear(around: catcherPanel.convertPoint(fromScreen: NSEvent.mouseLocation))
        }
        guard let view else { return }
        let animating = view.isAnimating
        if animating || wasAnimating { view.needsDisplay = true }
        wasAnimating = animating
    }
}

private final class InkView: NSView {
    var scene = InkScene()
    private let clock: () -> TimeInterval

    init(frame: CGRect, clock: @escaping () -> TimeInterval) {
        self.clock = clock
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used") }

    override var isFlipped: Bool { true }

    /// Whether something is fading or pulsing now.
    var isAnimating: Bool {
        let now = clock()
        return scene.lines.contains { $0.endedAt.map { now - $0 < InkOverlayController.linger + InkOverlayController.fade } ?? false }
            || scene.pins.contains { now - $0.droppedAt < InkOverlayController.pulse }
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = clock()
        let marker = NSColor(Palette.marker)
        for line in scene.lines where line.points.count > 1 {
            var alpha = 1.0
            if let ended = line.endedAt {
                let since = now - ended - InkOverlayController.linger
                alpha = since <= 0 ? 1 : max(0, 1 - since / InkOverlayController.fade)
            }
            guard alpha > 0 else { continue }
            let path = NSBezierPath()
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: line.points[0])
            for point in line.points.dropFirst() { path.line(to: point) }
            marker.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
        for pin in scene.pins {
            let progress = (now - pin.droppedAt) / InkOverlayController.pulse
            guard progress < 1 else { continue }
            let radius = 8 + 20 * progress
            let ring = NSBezierPath(ovalIn: CGRect(x: pin.point.x - radius, y: pin.point.y - radius,
                                                   width: 2 * radius, height: 2 * radius))
            ring.lineWidth = 3
            marker.withAlphaComponent(1 - progress).setStroke()
            ring.stroke()
            let label = NSAttributedString(string: "\(pin.number)", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: marker.withAlphaComponent(1 - progress),
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: pin.point.x + 10, y: pin.point.y - 10 - size.height))
        }
    }
}

/// The fill that takes fingers on a touch screen: as faint as a touch still lands on, with a clear circle around the
/// pointer. Fingers reach it through a gesture recognizer that takes direct touches only, never the mouse.
private final class TouchCatcher: NSView {
    private let shape = CAShapeLayer()
    private var hole: CGPoint?
    private let report: @MainActor (NSPressGestureRecognizer, TouchCatcher) -> Void

    init(frame: CGRect, report: @escaping @MainActor (NSPressGestureRecognizer, TouchCatcher) -> Void) {
        self.report = report
        super.init(frame: frame)
        shape.fillColor = NSColor.black.withAlphaComponent(InkOverlayController.catcherAlpha).cgColor
        shape.fillRule = .evenOdd
        layer = shape
        wantsLayer = true
        let finger = NSPressGestureRecognizer(target: self, action: #selector(fingered(_:)))
        finger.allowedTouchTypes = [.direct]
        finger.buttonMask = 0
        finger.minimumPressDuration = 0
        addGestureRecognizer(finger)
        clear(around: CGPoint(x: -1000, y: -1000))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used") }

    @objc private func fingered(_ recognizer: NSPressGestureRecognizer) { report(recognizer, self) }

    /// Leaves the circle around `point`, in the window's coordinates, clear.
    func clear(around point: CGPoint) {
        guard point != hole else { return }
        hole = point
        let radius = InkOverlayController.pointerClearance
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = path
        CATransaction.commit()
    }
}
