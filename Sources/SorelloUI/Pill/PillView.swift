import AppKit
import DesignCore

/// Draws the pill (ARCHITECTURE.md, section 8, "The pill"): the body that morphs between forms on the spring, the
/// cancel bud joined to it, and what each form holds, which fades out before the next fades in. Everything is a Core
/// Animation layer; a display link runs only while something moves and the view is on screen, at most 60 frames a
/// second, and each frame writes only what changed. It draws and takes no clicks: the overlay's controls panel does.
///
/// The view covers part of one screen; `origin` is the screen point (top left, y down) at its top-left corner, so the
/// geometry, which is in screen points, can be drawn wherever the panel is.
final class PillView: NSView {
    /// A fixed voice and moment, for snapshots: the wave draws this trace instead of the feed's.
    struct FixedWave {
        var trace: DotWave.Trace
        var now: Double
        var level: Double
    }

    /// The screen point at the view's top-left corner.
    var origin: CGPoint = .zero {
        didSet { if origin != oldValue { render(at: CACurrentMediaTime()) } }
    }
    /// Called once each time the pill has gone back to rest after being hidden, so the overlay can take its panels
    /// off the screen.
    var onRest: (() -> Void)?
    /// The control held down, drawn dimmer.
    var pressed: PillControl.Kind? {
        didSet { if pressed != oldValue { render(at: CACurrentMediaTime()) } }
    }
    private(set) var scene: PillScene?

    private let levels: LevelFeed?
    private let clock: () -> TimeInterval
    private let fixedWave: FixedWave?
    private let fixedMotionTime: CFTimeInterval?

    private var screen: ScreenTopology?
    private var adjustments = PillAdjustments()
    private var look = PillAppearance()
    private var body: MovingBody?
    private var bud = CancelBud.Model()
    private var recorder = DotWave.Recorder()
    private var restReported = true

    private let edge = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let contentHolder = CALayer()
    private let contentMask = CAShapeLayer()
    private let glyph = CAShapeLayer()
    private var current: PillContent?
    private var leaving: [PillContent] = []
    private var link: CADisplayLink?
    private var timeTimer: Timer?

    /// `levels` feeds the wave, read at `clock()`, the session's monotonic time, which the displays' start times are
    /// on. Snapshots pass a `fixedWave` and a `fixedMotionTime` so the picture never depends on the clock.
    init(levels: LevelFeed?, clock: @escaping () -> TimeInterval, fixedWave: FixedWave? = nil,
         fixedMotionTime: CFTimeInterval? = nil) {
        self.levels = levels
        self.clock = clock
        self.fixedWave = fixedWave
        self.fixedMotionTime = fixedMotionTime
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }
        root.actions = ["sublayers": NSNull()]
        edge.fillColor = nil
        edge.lineJoin = .round
        glyph.fillColor = nil
        glyph.strokeColor = NSColor(Palette.ink).cgColor
        glyph.lineWidth = 1.6
        glyph.lineCap = .round
        contentHolder.mask = contentMask
        for part in [edge, fill, contentHolder, glyph] as [CALayer] { root.addSublayer(part) }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func accessibilityChildren() -> [Any]? { [] }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit {
        MainActor.assumeIsolated {
            link?.invalidate()
            timeTimer?.invalidate()
        }
    }

    private var motionNow: CFTimeInterval { fixedMotionTime ?? CACurrentMediaTime() }

    // MARK: - What to show

    /// Shows `display` on `screen`. `animated` false puts everything in place at once (a pill appearing on a new
    /// screen, snapshots); otherwise the body springs and the content hands over, or with Reduce Motion cross-fades.
    func update(display: PillDisplay, screen: ScreenTopology, adjustments: PillAdjustments,
                appearance: PillAppearance, animated: Bool) {
        let now = motionNow
        let next = PillScene(display: display, screen: screen, adjustments: adjustments)
        let wasHidden = scene.map { $0.display == .hidden } ?? true
        // A pill that is up and changes screens or nudges takes its new place at once; one that is appearing grows
        // out of the new screen's housing.
        let moved = !wasHidden && (screen != self.screen || adjustments != self.adjustments)
        let travels = animated && !appearance.reduceMotion && !moved
        let fades = animated && !moved
        self.screen = screen
        self.adjustments = adjustments
        self.look = appearance
        layer?.contentsScale = screen.scale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if fades, appearance.reduceMotion {
            // Nothing travels: the old form cross-fades into the new.
            for part in [edge, fill, glyph] as [CALayer] {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = Motion.crossFade
                part.add(fade, forKey: "fade")
            }
        }
        moveBody(to: next, from: wasHidden, travels: travels, at: now)
        handOver(to: next, animated: fades, at: now)
        applyLook(showing: display != .hidden, fades: fades && wasHidden != (display == .hidden), at: now)
        scene = next
        if display == .hidden, !wasHidden { restReported = false }
        CATransaction.commit()

        render(at: now)
        scheduleTime()
        runIfNeeded(at: now)
    }

    private func moveBody(to next: PillScene, from wasHidden: Bool, travels: Bool, at now: CFTimeInterval) {
        guard let screen else { return }
        let target = next.layout.body
        let rest = PillGeometry.layout(.rest, on: screen, adjustments: adjustments).body
        if body == nil { body = MovingBody(wasHidden ? rest : target) }
        if travels {
            if wasHidden { body?.snap(to: rest) }
            body?.move(to: target, at: now)
        } else {
            body?.snap(to: target)
        }
        let resting = next.layout.cancel.map { (centre: Double($0.midX), radius: Double($0.width) / 2) }
        bud.update(resting: resting, end: Double(target.frame.maxX), endRadius: Double(target.frame.height) / 2,
                   animated: travels, now: now)
    }

    /// The body's colours, and whether it shows. Where there is no housing to grow out of it fades in as it grows and
    /// out as it shrinks; beside a housing it is black over black and simply there.
    private func applyLook(showing: Bool, fades: Bool, at now: CFTimeInterval) {
        guard let screen else { return }
        let floating = screen.kind == .none
        fill.fillColor = NSColor(floating ? Palette.pill : Palette.housing).cgColor
        // Beside a housing the body merges with the hardware: no edge, unless Increase Contrast asks for one.
        edge.isHidden = !(floating || look.increaseContrast)
        edge.strokeColor = NSColor(Palette.edge).cgColor
        // Twice the edge: its inner half lies under the fill, so exactly the edge's width shows, crisp, and the fill's
        // own antialiased rim never meets the backdrop.
        edge.lineWidth = CGFloat(2 * Palette.edgeWidth(highContrast: look.increaseContrast))
        let opacity: Float = floating && !showing ? 0 : 1
        for part in [edge, fill] {
            if fades, floating, part.opacity != opacity {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = part.opacity
                fade.toValue = opacity
                fade.duration = Motion.appear
                // Leaving, the content goes first.
                fade.beginTime = part.convertTime(now, from: nil) + (showing ? 0 : Motion.handover)
                fade.fillMode = .backwards
                part.add(fade, forKey: "appear")
            }
            part.opacity = opacity
        }
    }

    private func handOver(to next: PillScene, animated: Bool, at now: CFTimeInterval) {
        let key = PillContent.Key(next.display)
        if let current, current.key == key {
            current.configure(next, view: self)
            return
        }
        let reduce = look.reduceMotion
        let replacing = current != nil
        if let current {
            current.leave(at: now, animated: animated, duration: reduce ? Motion.crossFade : Motion.handover)
            leaving.append(current)
            self.current = nil
        }
        guard let key else { return }
        let content = PillContent(key: key, arrived: now)
        content.configure(next, view: self)
        contentHolder.addSublayer(content.layer)
        if animated {
            // What leaves goes first; with Reduce Motion the two cross-fade.
            content.arrive(at: now, delay: replacing && !reduce ? Motion.handover : 0,
                           duration: reduce ? Motion.crossFade : Motion.arrival)
        }
        if case .listening = key { recorder = DotWave.Recorder() }
        current = content
    }

    // MARK: - Drawing

    override func layout() {
        super.layout()
        render(at: motionNow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopLink()
        } else {
            runIfNeeded(at: motionNow)
        }
    }

    /// The screen point `point` (top left, y down) in the layer's coordinates.
    func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - origin.x, y: bounds.height - (point.y - origin.y))
    }

    /// The screen rectangle `rect` (top left, y down) in the layer's coordinates.
    func local(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - origin.x, y: bounds.height - (rect.maxY - origin.y), width: rect.width,
               height: rect.height)
    }

    var scale: CGFloat { CGFloat(screen?.scale ?? 2) }
    var reduceMotion: Bool { look.reduceMotion }
    var increaseContrast: Bool { look.increaseContrast }

    /// Draws the moment `now`: the body, the bud, and the moving content.
    private func render(at now: CFTimeInterval) {
        guard let body, let scene else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bud.advance(to: now)
        let shape = body.body(at: now)
        let endRadius = Double(shape.frame.height) / 2
        let budY = Double(scene.layout.cancel?.midY ?? shape.frame.midY)
        let budFrame = bud.frame(at: now, end: Double(shape.frame.maxX), endRadius: endRadius, y: budY)
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -origin.x, ty: bounds.height + origin.y)
        let outline = PillPath.outline(shape, bud: budFrame, budY: budY).copy(using: &flip)
        edge.path = outline
        fill.path = outline
        contentMask.path = outline
        for part in [edge, fill, contentHolder, contentMask, glyph] as [CALayer] { part.frame = bounds }

        if let budFrame {
            let centre = local(CGPoint(x: budFrame.centre, y: budY))
            let arm = 3.6
            let cross = CGMutablePath()
            cross.move(to: CGPoint(x: centre.x - arm, y: centre.y - arm))
            cross.addLine(to: CGPoint(x: centre.x + arm, y: centre.y + arm))
            cross.move(to: CGPoint(x: centre.x - arm, y: centre.y + arm))
            cross.addLine(to: CGPoint(x: centre.x + arm, y: centre.y - arm))
            glyph.path = cross
            glyph.opacity = Float(budFrame.glyphAlpha * (pressed == .cancel ? 0.5 : 1))
            glyph.isHidden = false
        } else {
            glyph.isHidden = true
        }

        let sessionNow = fixedWave?.now ?? clock()
        if let current {
            current.place(scene, view: self)
            if case .listening = current.key {
                var trace = recorder.trace, level = recorder.level
                if let fixedWave {
                    trace = fixedWave.trace
                    level = fixedWave.level
                } else if let levels {
                    let reading = levels.level(at: sessionNow)
                    recorder.record(reading.level, capture: reading.capture, at: sessionNow)
                    trace = recorder.trace
                    level = reduceMotion ? reading.level : recorder.level
                }
                current.drawWave(scene, trace: trace, level: level, now: sessionNow, view: self)
            } else if case .waiting = current.key {
                current.drawShimmer(scene, sweep: DotWave.sweep(at: now - current.arrived), view: self)
            }
            current.dim(pressed == .stop ? 0.6 : 1, action: pressedAction)
        }
        leaving.removeAll { content in
            guard let end = content.leftAt, now >= end else { return false }
            content.layer.removeFromSuperlayer()
            return true
        }
        CATransaction.commit()

        if scene.display == .hidden, !restReported, body.isSettled(at: now), !bud.isShowing {
            restReported = true
            onRest?()
        }
    }

    private var pressedAction: String? {
        if case .action(_, let id) = pressed { return id }
        return nil
    }

    // MARK: - The clock

    /// Whether anything moves at `now`: the body or the bud on their springs, the live wave (which with Reduce Motion
    /// still changes at each level, without travelling), or the shimmer.
    private func needsFrames(at now: CFTimeInterval) -> Bool {
        guard let body, let scene else { return false }
        if !body.isSettled(at: now) || bud.needsFrames(at: now) { return true }
        if scene.display == .hidden { return !restReported }
        switch scene.display {
        case .listening: return true
        case .waiting: return !reduceMotion
        case .hidden, .notice: return false
        }
    }

    private func runIfNeeded(at now: CFTimeInterval) {
        guard fixedMotionTime == nil, window != nil, needsFrames(at: now) else { return }
        let wanted: Float = reduceMotion && body?.isSettled(at: now) == true ? 15 : 60
        if let link, link.preferredFrameRateRange.maximum == wanted { return }
        stopLink()
        let link = displayLink(target: PillTick(self), selector: #selector(PillTick.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(wanted, 30), maximum: wanted, preferred: wanted)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        render(at: now)
        if !needsFrames(at: now) {
            stopLink()
        } else if reduceMotion, link.preferredFrameRateRange.maximum > 15, body?.isSettled(at: now) == true {
            runIfNeeded(at: now)
        }
    }

    /// While listening, redraws the elapsed time at each whole second of it.
    private func scheduleTime() {
        timeTimer?.invalidate()
        timeTimer = nil
        guard fixedMotionTime == nil, case .listening(let listening) = scene?.display else { return }
        let elapsed = clock() - listening.started
        let untilNext = max(1 - elapsed.truncatingRemainder(dividingBy: 1), 0.01)
        let timer = Timer(timeInterval: untilNext, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let scene = self.scene else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.current?.configure(scene, view: self)
                CATransaction.commit()
                self.scheduleTime()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timeTimer = timer
    }

    /// The elapsed time for a listening display, at the clock's now (snapshots: twelve seconds in).
    func elapsed(since started: TimeInterval) -> TimeInterval {
        fixedMotionTime == nil ? clock() - started : 12
    }
}

/// The display link's target, which holds the view weakly: a display link retains its target.
private final class PillTick: NSObject {
    private weak var view: PillView?

    init(_ view: PillView) {
        self.view = view
    }

    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            guard let view else { return link.invalidate() }
            view.tick(link)
        }
    }
}
