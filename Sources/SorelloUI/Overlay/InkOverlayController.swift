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

/// A transparent window over one display that draws a note's ink and pins. It never takes the mouse or the keyboard,
/// is never shared or recorded, and shows on every Space. A stroke fades 1.5 s after it ends; a pin shows as a ring
/// that grows and fades.
@MainActor
public final class InkOverlayController {
    /// How long an ended stroke stays before it fades, and how long the fade takes.
    public static let linger: TimeInterval = 1.5
    public static let fade: TimeInterval = 0.5
    /// How long a pin's ring lasts.
    public static let pulse: TimeInterval = 0.8

    private var panel: NSPanel?
    private var view: InkView?
    private var timer: Timer?
    private var wasAnimating = false
    private let clock: () -> TimeInterval

    /// `clock` is the same as the scene's times.
    public init(clock: @escaping () -> TimeInterval) {
        self.clock = clock
    }

    /// Puts the overlay over `frame`, a display's frame in the global AppKit space.
    public func show(on frame: CGRect) {
        hide()
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        let view = InkView(frame: CGRect(origin: .zero, size: frame.size), clock: clock)
        panel.contentView = view
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
        self.view = view
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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
    }

    /// Redraws while something fades or pulses, and once more as the last of it ends, so nothing is left half faded.
    private func tick() {
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
