import AppKit
import DesignCore

/// What one form of the pill holds, in a layer of its own, so a change of form can fade the old content out before
/// the new fades in (ARCHITECTURE.md, section 8, "Motion"): the wave and the time, the wait's row and its words, or a
/// notice's symbol, line and actions. Changes within a form (the time ticking, a notice's text) update it in place.
final class PillContent {
    /// Which content this is. A new key is a new form, or a new dictation, or a new notice: it fades in afresh.
    enum Key: Equatable {
        case listening(PillDisplay.Listening)
        case waiting(PillDisplay.Waiting)
        case notice(UInt64)

        init?(_ display: PillDisplay) {
            switch display {
            case .hidden: return nil
            case .listening(let listening): self = .listening(listening)
            case .waiting(let waiting): self = .waiting(waiting)
            case .notice(let notice): self = .notice(notice.id)
            }
        }
    }

    let key: Key
    /// When it arrived, on the motion clock: the wait's sweep starts from its left end then.
    let arrived: CFTimeInterval
    /// When it has finished fading out, once it is leaving.
    private(set) var leftAt: CFTimeInterval?
    /// Fades in and out, frame by frame on the motion clock.
    let layer = CALayer()
    private var fade = Fade(1)
    /// Dims while its control is held.
    private let inner = CALayer()
    private let dots = DotLayers()
    private let mark = CALayer()
    private let time = CALayer()
    private let tag = CALayer()
    private let words = CALayer()
    private let symbol = CALayer()
    private let text = CALayer()
    private var actions: [(id: String, capsule: CALayer, title: CALayer)] = []
    private var images: [ObjectIdentifier: PillImage] = [:]
    /// The time drawn, and the room it was drawn in.
    private var shownTime: (text: String, room: CGFloat)?
    /// The scale and contrast the cached images were drawn for.
    private var drawnFor: (scale: CGFloat, contrast: Bool)?

    init(key: Key, arrived: CFTimeInterval) {
        self.key = key
        self.arrived = arrived
        layer.addSublayer(inner)
        inner.addSublayer(dots.parent)
        mark.backgroundColor = NSColor(Palette.aurora).cgColor
        mark.isHidden = true
        for part in [mark, time, tag, words, symbol, text] {
            part.contentsGravity = .resize
            inner.addSublayer(part)
        }
    }

    // MARK: - Fading

    /// Fades in from nothing at `now`, after `delay`.
    func arrive(at now: CFTimeInterval, delay: Double, duration: Double) {
        fade = Fade(0)
        fade.move(to: 1, at: now, delay: delay, duration: duration)
        showFade(at: now)
    }

    /// Fades out from where it is at `now`, or, not `animated`, goes at once.
    func leave(at now: CFTimeInterval, animated: Bool, duration: Double) {
        leftAt = now + (animated ? duration : 0)
        if animated {
            fade.move(to: 0, at: now, duration: duration)
        } else {
            fade.snap(to: 0)
        }
        showFade(at: now)
    }

    /// Sets the opacity the fade has at `now`.
    func showFade(at now: CFTimeInterval) {
        let opacity = Float(fade.value(at: now))
        if layer.opacity != opacity { layer.opacity = opacity }
    }

    /// Whether it is fading in or out at `now`.
    func isFading(at now: CFTimeInterval) -> Bool { !fade.isSettled(at: now) }

    /// The frames of the lines and symbols it draws, in the view's coordinates.
    var drawnFrames: [CGRect] {
        ([time, tag, words, symbol, text] + actions.map(\.title)).filter { !$0.isHidden && $0.contents != nil }
            .map(\.frame)
    }

    func dim(_ alpha: Float, action: String?) {
        if inner.opacity != alpha { inner.opacity = alpha }
        for entry in actions {
            let wanted: Float = entry.id == action ? 0.6 : 1
            if entry.capsule.opacity != wanted {
                entry.capsule.opacity = wanted
                entry.title.opacity = wanted
            }
        }
    }

    // MARK: - Content

    /// Renders what this form holds for `scene` (the time's text, the notice's line and actions) and places it.
    func configure(_ scene: PillScene, view: PillView) {
        let scale = view.scale
        let secondary = NSColor(Palette.ink, alpha: view.increaseContrast ? 0.8 : Palette.secondaryInkAlpha)
        if drawnFor.map({ $0.scale != scale || $0.contrast != view.increaseContrast }) ?? false {
            // Another screen's scale, or Increase Contrast turned on or off: every image is drawn again.
            images = [:]
            shownTime = nil
        }
        drawnFor = (scale, view.increaseContrast)
        switch scene.display {
        case .listening(let listening):
            let shown = PillScene.elapsedText(view.elapsed(since: listening.started))
            // Its box, less the tag's room: on a screen too narrow for the time it is truncated there.
            let tagRoom = listening.promptStyle ? PillType.tagRoom : 0
            let room = max((scene.layout.trailing?.width ?? 0) - tagRoom, 0)
            if shownTime.map({ $0.text != shown || $0.room != room }) ?? true {
                shownTime = (shown, room)
                set(time, room > 0 ? PillImage.text(shown, font: PillType.time, color: NSColor(Palette.ink),
                                                    maxWidth: room, scale: scale) : nil)
            }
            if listening.promptStyle, images[ObjectIdentifier(tag)] == nil {
                set(tag, PillImage.symbol(PillType.tagSymbol, pointSize: PillType.tagSize, weight: .semibold, color: secondary,
                                          scale: scale))
            }
        case .waiting(.preparingModel):
            let width = scene.layout.trailing?.width ?? 0
            set(words, PillImage.text(PillScene.preparingText, font: PillType.words, color: secondary,
                                      maxWidth: width, scale: scale))
        case .notice(let notice):
            configureNotice(notice, scene, view: view)
        case .waiting(.transcribing), .hidden:
            break
        }
        place(scene, view: view)
    }

    private func configureNotice(_ notice: PillDisplay.Notice, _ scene: PillScene, view: PillView) {
        guard let inner = scene.notice else { return }
        let scale = view.scale
        let tone = notice.tone == .error ? NSColor(Palette.ember) : NSColor(Palette.ink)
        set(symbol, PillImage.symbol(notice.symbol, pointSize: PillType.symbolSize, weight: .semibold, color: tone,
                                     scale: scale))
        set(text, PillImage.text(notice.text, font: PillType.notice, color: NSColor(Palette.ink),
                                 maxWidth: inner.text.width, scale: scale))
        for entry in actions {
            entry.capsule.removeFromSuperlayer()
            entry.title.removeFromSuperlayer()
        }
        actions = []
        for (action, rect) in zip(notice.actions, inner.actions) {
            let capsule = CALayer(), title = CALayer()
            title.contentsGravity = .resize
            capsule.cornerRadius = rect.height / 2
            if action.isPrimary {
                capsule.backgroundColor = NSColor(Palette.ink).cgColor
            } else {
                capsule.backgroundColor = NSColor(Palette.ink, alpha: 0.14).cgColor
                capsule.borderColor = NSColor(Palette.ink, alpha: view.increaseContrast ? 0.6 : 0.22).cgColor
                capsule.borderWidth = view.increaseContrast ? 1 : 0.5
            }
            let ink = action.isPrimary ? NSColor(Palette.pill) : NSColor(Palette.ink)
            self.inner.addSublayer(capsule)
            self.inner.addSublayer(title)
            set(title, PillImage.text(action.title, font: PillType.action, color: ink,
                                      maxWidth: max(rect.width - 2 * PillType.actionPadding + 2, 1), scale: scale))
            actions.append((action.id, capsule, title))
        }
    }

    /// Places the content for `scene` in the view's coordinates, which move when the panel does.
    func place(_ scene: PillScene, view: PillView) {
        layer.frame = view.bounds
        inner.frame = view.bounds
        dots.parent.frame = view.bounds
        let layout = scene.layout
        switch scene.display {
        case .listening:
            guard let box = layout.trailing else { break }
            let timeImage = images[ObjectIdentifier(time)]
            // The time sits at the end of its box, as the wave starts at the start of its own.
            let timeX = box.maxX - (timeImage?.size.width ?? 0)
            placeText(time, x: timeX, middle: box.midY, font: PillType.time, view: view)
            if let tagImage = images[ObjectIdentifier(tag)] {
                let x = timeX - PillType.tagGap - tagImage.size.width
                placeCentred(tag, x: x, middle: box.midY, view: view)
            }
        case .waiting(.preparingModel):
            guard let box = layout.trailing else { break }
            placeText(words, x: box.minX, middle: box.midY, font: PillType.words, view: view)
        case .notice:
            guard let card = layout.card, let inner = scene.notice else { break }
            let symbolBox = inner.symbol.offsetBy(dx: card.minX, dy: card.minY)
            placeCentred(symbol, x: nil, middle: symbolBox.midY, view: view, within: symbolBox)
            let textBox = inner.text.offsetBy(dx: card.minX, dy: card.minY)
            placeText(text, x: textBox.minX, middle: symbolBox.midY, font: PillType.notice, view: view)
            for (entry, rect) in zip(actions, inner.actions) {
                let box = rect.offsetBy(dx: card.minX, dy: card.minY)
                entry.capsule.frame = view.local(box)
                let titleWidth = images[ObjectIdentifier(entry.title)]?.size.width ?? 0
                placeText(entry.title, x: snap(box.midX - titleWidth / 2, view.scale), middle: box.midY,
                          font: PillType.action, view: view)
            }
        case .waiting(.transcribing), .hidden:
            break
        }
    }

    /// The wave and its aurora dot in its box, for the voice in `trace` at `now`.
    func drawWave(_ scene: PillScene, trace: DotWave.Trace, level: Double, now: Double, view: PillView) {
        guard let box = scene.layout.leading else { return }
        let wave = PillDots.wave(in: box, trace: trace, now: now, level: level, still: view.reduceMotion)
        dots.show(wave.dots.map { local($0, view) }, color: NSColor(Palette.ink).cgColor)
        if let dot = wave.mark {
            let at = local(dot, view)
            mark.isHidden = false
            mark.bounds = CGRect(x: 0, y: 0, width: 2 * at.radius, height: 2 * at.radius)
            mark.cornerRadius = at.radius
            mark.position = CGPoint(x: at.x, y: at.y)
        } else {
            mark.isHidden = true
        }
    }

    /// The wait's row with its spot at `sweep`; with Reduce Motion, still, its middle lit.
    func drawShimmer(_ scene: PillScene, sweep: Double, view: PillView) {
        guard let box = scene.layout.leading else { return }
        let row = PillDots.shimmer(in: box, sweep: sweep, still: view.reduceMotion)
        dots.show(row.map { local($0, view) }, color: NSColor(Palette.shimmer).cgColor)
    }

    // MARK: - Helpers

    private func set(_ layer: CALayer, _ image: PillImage?) {
        images[ObjectIdentifier(layer)] = image
        layer.contents = image?.image
        layer.isHidden = image == nil
    }

    private func local(_ dot: DotWave.Dot, _ view: PillView) -> DotWave.Dot {
        let point = view.local(CGPoint(x: dot.x, y: dot.y))
        return DotWave.Dot(x: Double(point.x), y: Double(point.y), radius: dot.radius, brightness: dot.brightness)
    }

    /// A line of text with its left edge at `x`, optically centred on the screen line `middle`: the middle of its
    /// capitals there, its baseline on a whole pixel.
    private func placeText(_ layer: CALayer, x: CGFloat, middle: CGFloat, font: NSFont, view: PillView) {
        guard let image = images[ObjectIdentifier(layer)] else { return }
        let baseline = snap(middle + font.capHeight / 2, view.scale)
        layer.frame = view.local(CGRect(x: snap(x, view.scale), y: baseline - image.ascent, width: image.size.width,
                                        height: image.size.height))
    }

    /// An image centred on the screen line `middle`, at `x` or centred in `within`, on whole pixels.
    private func placeCentred(_ layer: CALayer, x: CGFloat?, middle: CGFloat, view: PillView, within: CGRect? = nil) {
        guard let image = images[ObjectIdentifier(layer)] else { return }
        let left = x ?? (within.map { $0.midX - image.size.width / 2 } ?? 0)
        layer.frame = view.local(CGRect(x: snap(left, view.scale), y: snap(middle - image.size.height / 2, view.scale),
                                        width: image.size.width, height: image.size.height))
    }

    private func snap(_ value: CGFloat, _ scale: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
}
