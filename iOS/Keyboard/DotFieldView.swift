import QuartzCore
import SwiftUI
import UIKit

/// The island's dots (ARCHITECTURE.md, "Keyboard look"): the recording wave (`DotWave.dots`, with the mark's dot), the
/// ring opening into it (`RingOpening`), or the wait's shimmer (`DotWave.shimmer`), each dot a small layer that Core
/// Animation composites, not a SwiftUI `Canvas` inside `TimelineView(.animation)`, which in some keyboard processes
/// draws nothing at all for the rest of the process. Every change of size, level or colour draws a frame at once, so
/// the first frame never waits for a clock, and a display link moves the dots only while the view is in a window, shown,
/// and animating (the opening, recording, or the wait's sweep), at most 60 frames a second. While recording, each frame
/// records the followed level into the wave's trace (`DotWave.Trace`), which the row shows.
struct DotFieldRepresentable: UIViewRepresentable {
    let kind: DotFieldView.Kind
    /// The latest input level, 0 to 1.
    let level: Double
    let ink: BrandPalette.RGB
    /// The mark's dot at the wave's right end, if any.
    let mark: BrandPalette.RGB?
    let reduceMotion: Bool
    /// Left to right reversed (the left-handed island, where the mark's dot is at the wave's left).
    var mirrored = false
    /// The wave's row dimmed, as while the microphone starts.
    var dimmed = false
    /// Where the dots lie in the view; nil, the whole view.
    var box: CGRect?
    /// Start's ring, given as the wave arrives (`DotFieldView.Kind.idle` to `.wave`), opens into it; nil then, no opening.
    var opening: DotFieldView.Opening?

    func makeUIView(context: Context) -> DotFieldView { DotFieldView() }

    func updateUIView(_ view: DotFieldView, context: Context) {
        view.configure(kind: kind, level: level, ink: ink, mark: mark, reduceMotion: reduceMotion, mirrored: mirrored,
                       dimmed: dimmed, box: box, opening: opening)
    }
}

final class DotFieldView: UIView {
    enum Kind: Equatable {
        /// Nothing new: the last frame stays as it was (while it fades), and nothing moves.
        case idle
        /// The recording wave; `live` while recording (it follows the voice), otherwise its still, calm row.
        case wave(live: Bool)
        /// The wait's shimmer.
        case shimmer
    }

    /// Start's ring as it opens into the wave (ARCHITECTURE.md, "Keyboard look", "The opening"): Start's mark box in
    /// this view, its ring mirrored with the view's dots. Its dots are the wave's ink and its state dot the wave's mark.
    struct Opening: Equatable {
        var ring: CGRect
    }

    /// While the microphone starts, the row is dimmed to this; it brightens in `dimDuration` when the recording begins.
    static let dimmedAlpha = 0.55
    static let dimDuration = 0.15

    private var kind = Kind.wave(live: false)
    private var level = 0.0
    private var ink = BrandPalette.RGB(1, 1, 1)
    private var mark: BrandPalette.RGB?
    private var reduceMotion = false
    private var mirrored = false
    private var box: CGRect?
    private var opening: Opening?
    /// When the opening began; nil when none is running.
    private var openedAt: CFTimeInterval?
    private var dimmed = false
    /// The last change of `dimmed`: when, and how dim the row was then.
    private var dimChange: (time: CFTimeInterval, alpha: Double)?

    private var follower = DotWave.LevelFollower()
    private var trace = DotWave.Trace()
    private var lastFrame: CFTimeInterval?
    private var link: CADisplayLink?
    private var dotLayers: [DotLayer] = []
    private let markLayer = DotLayer()
    /// Holds the dots, and dims them all alike.
    private let field = CALayer()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = false
        field.actions = DotLayer.still
        layer.addSublayer(field)
        field.addSublayer(markLayer.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        link?.invalidate()
    }

    func configure(kind: Kind, level: Double, ink: BrandPalette.RGB, mark: BrandPalette.RGB?, reduceMotion: Bool,
                   mirrored: Bool, dimmed: Bool = false, box: CGRect? = nil, opening: Opening? = nil) {
        let now = CACurrentMediaTime()
        if kind != self.kind {
            // A new recording starts its level and its row from rest.
            follower = DotWave.LevelFollower()
            trace = DotWave.Trace()
            lastFrame = nil
        }
        // The ring opens when the wave arrives with it, never with Reduce Motion. Once open it runs its course while the
        // wave shows (the recording may begin meanwhile); any other change ends it at once, and what follows hands over
        // as before.
        if case .wave = kind, self.kind == .idle, let opening, !reduceMotion {
            openedAt = now
            self.opening = opening
        } else if reduceMotion || kind == .idle || kind == .shimmer {
            openedAt = nil
        }
        if dimmed != self.dimmed {
            // The shown row brightens (or dims) in a moment; a row that arrives does so already as it is.
            if case .wave = kind, case .wave = self.kind {
                dimChange = (now, dimAlpha(at: now))
            } else {
                dimChange = nil
            }
        }
        self.mirrored = mirrored
        self.kind = kind
        self.level = level
        self.ink = ink
        self.mark = mark
        self.reduceMotion = reduceMotion
        self.dimmed = dimmed
        self.box = box
        updateClock()
        render(at: now)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        field.frame = bounds
        render(at: CACurrentMediaTime())
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateClock()
        render(at: CACurrentMediaTime())
    }

    override var isHidden: Bool {
        didSet { updateClock() }
    }

    /// Whether the dots move between changes: the opening, the live wave and the shimmer, never with Reduce Motion.
    private var animates: Bool {
        guard !reduceMotion else { return false }
        switch kind {
        case .idle: return false
        case .wave(let live): return live || openedAt != nil
        case .shimmer: return true
        }
    }

    /// How dim the row is at `now`: `dimmedAlpha` or 1, eased out over `dimDuration` from the last change.
    private func dimAlpha(at now: CFTimeInterval) -> Double {
        let target = dimmed ? Self.dimmedAlpha : 1
        guard let change = dimChange else { return target }
        let u = (now - change.time) / Self.dimDuration
        guard u < 1 else { return target }
        let eased = 1 - (1 - max(u, 0)) * (1 - max(u, 0))
        return change.alpha + (target - change.alpha) * eased
    }

    /// Runs the display link only while the dots move and can be seen.
    private func updateClock() {
        let wanted = animates && window != nil && !isHidden
        if wanted, link == nil {
            let link = CADisplayLink(target: Tick(self), selector: #selector(Tick.fire(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: Float(1 / DotWave.frameInterval),
                                                            preferred: Float(1 / DotWave.frameInterval))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !wanted, let link {
            link.invalidate()
            self.link = nil
            lastFrame = nil
        }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        render(at: link.targetTimestamp)
        if !animates { updateClock() }
    }

    /// Lays the dots out for the moment `now`: the level advanced to it while the wave is live, and the ring opened as far
    /// as the opening has come.
    private func render(at now: CFTimeInterval) {
        let box = box ?? bounds
        let width = Double(box.width), height = Double(box.height)
        var dots: [DotWave.Dot] = []
        var markDot: DotWave.Dot?
        var alpha = dimAlpha(at: now)
        switch kind {
        case .idle:
            // The last frame stays as it was.
            return
        case .wave(let live):
            var shown = live ? level : 0
            if live && !reduceMotion {
                // Only a frame after the last moves the row (layout and a new level draw at the same moment again).
                if now > (lastFrame ?? -.infinity) {
                    follower.follow(level, over: min(now - (lastFrame ?? now), 0.1))
                    trace.record(follower.value, at: now)
                    lastFrame = now
                }
                shown = follower.value
                dots = DotWave.dots(trace: trace, now: now, width: width, height: height)
            } else {
                // Still: the calm row while starting; with Reduce Motion, the row stands at each level.
                dots = DotWave.dots(level: shown, width: width, height: height)
            }
            if mark != nil, !dots.isEmpty { markDot = DotWave.markDot(level: shown, width: width, height: height) }
        case .shimmer:
            let period = DotWave.shimmerPeriod
            let sweep = animates ? (now.truncatingRemainder(dividingBy: period) / period) * 1.6 - 0.3 : -1
            dots = DotWave.shimmer(sweep: sweep, width: width, height: height)
        }
        // Into the view's coordinates, mirrored across the box left-handed.
        let x0 = Double(box.minX), y0 = Double(box.minY)
        func place(_ dot: DotWave.Dot) -> DotWave.Dot {
            DotWave.Dot(x: x0 + (mirrored ? width - dot.x : dot.x), y: y0 + dot.y, radius: dot.radius, brightness: dot.brightness)
        }
        dots = dots.map(place)
        markDot = markDot.map(place)
        if let openedAt, let opening, let target = markDot {
            let progress = (now - openedAt) / RingOpening.duration
            if progress < 1 {
                // The ring's dots on their way to the row as the wave would draw it now: the calm row while the microphone
                // starts, the voice once the recording begins. Start's ring is not dimmed; the row is, as it arrives.
                let ring = KeyRect(x: Double(opening.ring.minX), y: Double(opening.ring.minY),
                                   width: Double(opening.ring.width), height: Double(opening.ring.height))
                let frame = RingOpening.frame(ring: ring, row: dots, mark: target, progress: progress, mirrored: mirrored)
                dots = frame.dots
                markDot = frame.stateDot
                alpha = 1 + (alpha - 1) * RingOpening.eased(progress)
            } else {
                // Opened: the wave from here on (`tick` stops the clock unless the wave is live).
                self.openedAt = nil
            }
        }
        // No transaction of its own: the dots change in the same commit as the SwiftUI update that asked for them, so the
        // ring's first moment never shows ahead of the rest of the island (the layers have no implicit animations).
        while dotLayers.count < dots.count {
            let dot = DotLayer()
            field.insertSublayer(dot.layer, below: markLayer.layer)
            dotLayers.append(dot)
        }
        for (index, dotLayer) in dotLayers.enumerated() {
            if index < dots.count {
                dotLayer.show(dots[index], color: ink)
            } else {
                dotLayer.hide()
            }
        }
        if let markDot, let mark {
            markLayer.show(markDot, color: mark)
        } else {
            markLayer.hide()
        }
        setAlpha(alpha, at: now)
    }

    /// Dims the dots to `alpha`. Between frames (nothing else moving, or Reduce Motion) Core Animation runs what is left
    /// of a change of `dimmed`.
    private func setAlpha(_ alpha: Double, at now: CFTimeInterval) {
        let target = Float(dimmed ? Self.dimmedAlpha : 1)
        if link == nil, openedAt == nil, let change = dimChange, now - change.time < Self.dimDuration {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = Float(alpha)
            fade.toValue = target
            fade.duration = Self.dimDuration - (now - change.time)
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            field.add(fade, forKey: "dim")
            field.opacity = target
            dimChange = nil
        } else if field.opacity != Float(alpha) {
            field.removeAnimation(forKey: "dim")
            field.opacity = Float(alpha)
        }
    }
}

/// One dot's layer: a disc of the largest radius any dot has, scaled to the dot's, so a frame changes at most its scale
/// and opacity. It writes only what changed since its last frame, and Core Animation composites it.
private final class DotLayer {
    let layer = CALayer()
    private var shown: (x: Double, y: Double, scale: Double, opacity: Double, color: BrandPalette.RGB)?
    private static let diameter = 2 * max(DotWave.fullRadius, DotWave.markRadius * (1 + DotWave.markGrowth))
    /// No implicit animation for anything a frame changes: each frame sets where the dots are.
    static let still: [String: CAAction] = Dictionary(uniqueKeysWithValues: ["position", "transform", "opacity", "hidden",
        "backgroundColor", "bounds", "frame", "cornerRadius", "sublayers"].map { ($0, NSNull()) })

    init() {
        layer.actions = Self.still
        layer.bounds = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        layer.cornerRadius = Self.diameter / 2
        layer.isHidden = true
    }

    func show(_ dot: DotWave.Dot, color: BrandPalette.RGB) {
        let scale = 2 * dot.radius / Self.diameter, opacity = min(max(dot.brightness, 0), 1)
        let last = shown
        if last == nil { layer.isHidden = false }
        if last?.x != dot.x || last?.y != dot.y { layer.position = CGPoint(x: dot.x, y: dot.y) }
        if last.map({ abs($0.scale - scale) > 0.002 }) ?? true {
            layer.transform = CATransform3DMakeScale(CGFloat(scale), CGFloat(scale), 1)
        }
        if last.map({ abs($0.opacity - opacity) > 0.002 }) ?? true { layer.opacity = Float(opacity) }
        if last?.color != color { layer.backgroundColor = UIColor(color).cgColor }
        shown = (dot.x, dot.y, last.map { abs($0.scale - scale) > 0.002 ? scale : $0.scale } ?? scale,
                 last.map { abs($0.opacity - opacity) > 0.002 ? opacity : $0.opacity } ?? opacity, color)
    }

    func hide() {
        guard shown != nil else { return }
        layer.isHidden = true
        shown = nil
    }
}

/// The display link's target, which holds the view weakly: a display link retains its target.
private final class Tick: NSObject {
    private weak var view: DotFieldView?

    init(_ view: DotFieldView) {
        self.view = view
    }

    @objc func fire(_ link: CADisplayLink) {
        guard let view else { return link.invalidate() }
        view.tick(link)
    }
}
