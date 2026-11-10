import AppKit
import DesignCore

/// The pill's scenes for the snapshot tool (ARCHITECTURE.md, section 11): every state, for every camera housing, over
/// a menu bar on a wallpaper with the housing drawn in black so the merge shows; a contact sheet per housing; and the
/// mark, the menu-bar icon and the app icon.
public enum PillSnapshots {
    public static var scenes: [SnapshotScene] {
        Housing.allCases.flatMap { housing in
            states.map { state in
                SnapshotScene(name: "pill-\(housing.name)-\(state.name)", size: housing.crop.size) {
                    PillStage(housing: housing, state: state)
                }
            } + [contactSheet(for: housing), pixelPreview(for: housing)]
        } + MarkSnapshots.scenes
    }

    // MARK: - The screens

    /// A Mac to draw the pill on, and the part of its screen a picture shows.
    enum Housing: CaseIterable {
        case island, notch, none

        var name: String {
            switch self {
            case .island: "island"
            case .notch: "notch"
            case .none: "none"
            }
        }

        var title: String {
            switch self {
            case .island: "2026 MacBook Pro, camera island"
            case .notch: "14-inch MacBook Pro, notch"
            case .none: "External display"
            }
        }

        /// The 2026 MacBook Pro, a 14-inch 2021 MacBook Pro at its default scale, and an external display.
        var topology: ScreenTopology {
            switch self {
            case .island:
                ScreenTopology(frame: CGRect(x: 0, y: 0, width: 1736, height: 1133), safeAreaTop: 40,
                               leftAreaWidth: 838.5, rightAreaWidth: 838.5, menuBarHeight: 40, scale: 2)
            case .notch:
                ScreenTopology(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                               leftAreaWidth: 663.5, rightAreaWidth: 663.5, menuBarHeight: 32, scale: 2)
            case .none:
                ScreenTopology(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0, housing: nil,
                               menuBarHeight: 24, scale: 2)
            }
        }

        /// The top middle of the screen, where the pill is: wide enough for the widest card.
        var crop: CGRect {
            let topology = topology
            let middle = topology.housing?.midX ?? topology.width / 2
            return CGRect(x: middle - 300, y: 0, width: 600, height: 168)
        }
    }

    /// One state of the pill to draw.
    struct State {
        var name: String
        var caption: String
        var display: PillDisplay
        var appearance = PillAppearance()
        /// The voice the wave shows; silence unless given.
        var wave: PillView.FixedWave?
        /// The motion clock's moment, which places the wait's spot.
        var motionTime: CFTimeInterval = 0.62
    }

    static let started: TimeInterval = 1_000

    static var states: [State] {
        let hold = PillDisplay.listening(.init(trigger: .hold, started: started))
        var all = [
            State(name: "listening-silent", caption: "Listening, silence", display: hold, wave: silence),
            State(name: "listening-speaking", caption: "Listening, mid-sentence", display: hold, wave: speech),
            State(name: "listening-toggle", caption: "Tap to Toggle, with Cancel",
                  display: .listening(.init(trigger: .toggle, started: started)), wave: speech),
            State(name: "listening-prompt", caption: "Prompt style",
                  display: .listening(.init(trigger: .hold, promptStyle: true, started: started)), wave: speech),
            State(name: "waiting", caption: "Transcribing", display: .waiting(.transcribing)),
            State(name: "waiting-preparing", caption: "Preparing the model", display: .waiting(.preparingModel)),
            State(name: "notice-error", caption: "An error", display: errorNotice),
            State(name: "notice-suggestion", caption: "Dictionary suggestion", display: suggestion),
        ]
        let contrast = PillAppearance(increaseContrast: true), still = PillAppearance(reduceMotion: true)
        all += [
            State(name: "contrast-listening", caption: "Increase Contrast", display: hold, appearance: contrast,
                  wave: speech),
            State(name: "contrast-suggestion", caption: "Increase Contrast, notice", display: suggestion,
                  appearance: contrast),
            State(name: "reduce-motion-listening", caption: "Reduce Motion, listening", display: hold,
                  appearance: still, wave: PillView.FixedWave(trace: DotWave.Trace(), now: started + 12, level: 0.8)),
            State(name: "reduce-motion-waiting", caption: "Reduce Motion, waiting", display: .waiting(.transcribing),
                  appearance: still),
        ]
        return all
    }

    static let errorNotice = PillDisplay.notice(.init(
        id: 1, symbol: "exclamationmark.triangle.fill", tone: .error,
        text: String(localized: "The microphone stopped. Nothing was lost.")))

    static let suggestion = PillDisplay.notice(.init(
        id: 2, symbol: "character.book.closed.fill", tone: .information,
        text: String(localized: "Add \u{201C}Okonkwo\u{201D} to your dictionary?"),
        actions: [.init(id: "add", title: String(localized: "Add"), isPrimary: true),
                  .init(id: "later", title: String(localized: "Not Now")),
                  .init(id: "never", title: String(localized: "Don\u{2019}t Suggest"))]))

    static let silence = PillView.FixedWave(trace: DotWave.Trace(), now: started + 12, level: 0)

    /// An invented sentence's loudness, ten levels a second, as the meter would give it, recorded the way the pill
    /// records it: through the follower, a frame at a time.
    static var speech: PillView.FixedWave {
        let levels = [0.05, 0.2, 0.75, 0.95, 0.6, 0.15, 0.4, 0.85, 1.0, 0.7, 0.3, 0.1, 0.55, 0.9, 0.8]
        var recorder = DotWave.Recorder()
        let start = started + 12 - Double(levels.count) / 10
        for frame in 0 ... levels.count * 6 {
            let t = Double(frame) / 60
            recorder.record(levels[min(Int(t * 10), levels.count - 1)], capture: 1, at: start + t)
        }
        return PillView.FixedWave(trace: recorder.trace, now: start + Double(levels.count) / 10, level: recorder.level)
    }

    // MARK: - Sheets

    static func contactSheet(for housing: Housing) -> SnapshotScene {
        let states = Self.states
        let crop = housing.crop.size, columns = 2, caption: CGFloat = 22
        let rows = (states.count + columns - 1) / columns
        let size = CGSize(width: crop.width * CGFloat(columns), height: (crop.height + caption) * CGFloat(rows) + 34)
        return SnapshotScene(name: "pill-\(housing.name)-contact-sheet", size: size) {
            let sheet = SheetView(frame: CGRect(origin: .zero, size: size))
            sheet.title = housing.title
            for (index, state) in states.enumerated() {
                let column = index % columns, row = index / columns
                let origin = CGPoint(x: CGFloat(column) * crop.width,
                                     y: 34 + CGFloat(row) * (crop.height + caption))
                sheet.add(PillStage(housing: housing, state: state), caption: state.caption,
                          frame: CGRect(origin: origin, size: CGSize(width: crop.width, height: crop.height + caption)))
            }
            return sheet
        }
    }

    /// The listening pill as a 1x display draws it, every pixel shown as a 4 x 4 block, so a reviewer can judge it
    /// without a 1x screen.
    static func pixelPreview(for housing: Housing) -> SnapshotScene {
        var topology = housing.topology
        topology.scale = 1
        let crop = CGRect(x: housing.crop.midX - 200, y: 0, width: 400, height: 80)
        let state = states[2]
        return SnapshotScene(name: "pill-\(housing.name)-toggle-at-1x", size: CGSize(width: 800, height: 160)) {
            PixelPreview(stage: PillStage(housing: housing, state: state, topology: topology, crop: crop),
                         size: crop.size, magnification: 2)
        }
    }
}

/// One picture of the pill: a wallpaper, the menu bar across it, the camera housing in black, and the pill over them,
/// in a crop of the screen.
final class PillStage: NSView {
    private let wallpaper = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let menuBar = CALayer()
    private let housingShape = CAShapeLayer()
    private let pill: PillView
    private let topology: ScreenTopology
    private let crop: CGRect

    init(housing: PillSnapshots.Housing, state: PillSnapshots.State, topology: ScreenTopology? = nil,
         crop: CGRect? = nil) {
        let topology = topology ?? housing.topology
        self.topology = topology
        self.crop = crop ?? housing.crop
        pill = PillView(levels: nil, clock: { PillSnapshots.started + 12 }, fixedWave: state.wave,
                        fixedMotionTime: state.motionTime)
        super.init(frame: CGRect(origin: .zero, size: self.crop.size))
        wantsLayer = true
        guard let root = layer else { return }
        // A dusk wallpaper: deep blue into violet, a warm light low on one side.
        wallpaper.colors = [NSColor(srgbRed: 0.10, green: 0.16, blue: 0.32, alpha: 1).cgColor,
                            NSColor(srgbRed: 0.30, green: 0.22, blue: 0.46, alpha: 1).cgColor]
        wallpaper.startPoint = CGPoint(x: 0, y: 1)
        wallpaper.endPoint = CGPoint(x: 1, y: 0)
        glow.type = .radial
        glow.colors = [NSColor(srgbRed: 0.85, green: 0.45, blue: 0.40, alpha: 0.35).cgColor,
                       NSColor(srgbRed: 0.85, green: 0.45, blue: 0.40, alpha: 0).cgColor]
        glow.startPoint = CGPoint(x: 0.8, y: 0)
        glow.endPoint = CGPoint(x: 1.4, y: 0.9)
        menuBar.backgroundColor = NSColor(white: 0, alpha: 0.22).cgColor
        housingShape.fillColor = NSColor.black.cgColor
        for part in [wallpaper, glow, menuBar, housingShape] { root.addSublayer(part) }
        addSubview(pill)
        pill.update(display: state.display, screen: topology, adjustments: PillAdjustments(),
                    appearance: state.appearance, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaper.frame = bounds
        glow.frame = bounds
        let bar = CGFloat(topology.menuBarHeight)
        menuBar.frame = CGRect(x: 0, y: bounds.height - bar, width: bounds.width, height: bar)
        housingShape.frame = bounds
        if topology.kind != .none {
            let rest = PillGeometry.layout(.rest, on: topology).body
            var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -crop.minX, ty: bounds.height + crop.minY)
            housingShape.path = PillPath.rounded(rest).copy(using: &flip)
        }
        CATransaction.commit()
        pill.frame = bounds
        pill.origin = crop.origin
        pill.layoutSubtreeIfNeeded()
    }
}

/// A sheet of pictures with captions, for the contact sheets.
private final class SheetView: NSView {
    var title = ""
    private var captions: [(String, CGRect)] = []

    override var isFlipped: Bool { true }

    func add(_ view: NSView, caption: String, frame: CGRect) {
        view.frame = CGRect(x: frame.minX, y: frame.minY + 22, width: frame.width, height: frame.height - 22)
        addSubview(view)
        captions.append((caption, frame))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Palette.screen).setFill()
        bounds.fill()
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                                                      .foregroundColor: NSColor.white]
        (title as NSString).draw(at: CGPoint(x: 14, y: 8), withAttributes: heading)
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor(white: 1, alpha: 0.6)]
        for (caption, frame) in captions {
            (caption as NSString).draw(at: CGPoint(x: frame.minX + 14, y: frame.minY + 4), withAttributes: small)
        }
    }
}

/// Renders a view at 1x in its own off-screen window and shows the pixels magnified without smoothing.
private final class PixelPreview: NSView {
    private let image = CALayer()

    init(stage: NSView, size: CGSize, magnification: CGFloat) {
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: size.width * magnification,
                                                             height: size.height * magnification)))
        wantsLayer = true
        image.magnificationFilter = .nearest
        image.contentsGravity = .resize
        layer?.addSublayer(image)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        stage.frame = CGRect(origin: .zero, size: size)
        window.contentView = stage
        stage.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
                                         pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0) {
            bitmap.size = size
            stage.cacheDisplay(in: stage.bounds, to: bitmap)
            image.contents = bitmap.cgImage
        }
        window.close()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        image.frame = bounds
    }
}
