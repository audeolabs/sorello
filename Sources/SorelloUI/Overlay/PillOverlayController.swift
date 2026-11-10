import AppKit
import DesignCore

/// Puts the pill on the screen (ARCHITECTURE.md, section 8, "The pill"). It draws in one panel that ignores the mouse,
/// and offers each of the pill's controls (stop, cancel, a notice's actions) in a small panel exactly that control's
/// size, shown only while it is, so the pill never swallows a click meant for the menu bar. No panel takes keyboard
/// focus.
///
/// The pill appears on the screen with keyboard focus when a dictation starts (else the one under the pointer) and
/// stays there for that dictation; if that screen goes away it moves to the main one. Reduce Motion and Increase
/// Contrast are read from the system and followed as they change. VoiceOver hears each notice once, and the controls
/// as buttons; the moving level is never exposed to it.
@MainActor
public final class PillOverlayController {
    /// The user clicked the pill while it listens in toggle mode, or pressed it with VoiceOver.
    public var onStop: () -> Void = {}
    /// The user clicked the cancel button that buds off the pill in toggle mode.
    public var onCancel: () -> Void = {}
    /// The user clicked an action of the notice with that id.
    public var onNoticeAction: (_ notice: UInt64, _ action: String) -> Void = { _, _ in }

    /// What the pill shows now.
    public private(set) var display = PillDisplay.hidden
    /// The screen the pill is on, as it was read; nil while it has never been shown.
    public private(set) var topology: ScreenTopology?
    /// Where the pill's parts are for what it shows now, in the screen's points (top left, y down).
    public var layout: PillLayout? { view.scene?.layout }
    /// The drawing panel's frame in global coordinates while it is on the screen.
    public var drawingFrame: CGRect? { drawing.isVisible ? drawing.frame : nil }
    /// The control panels' frames in global coordinates, for those on the screen.
    public var controlFrames: [CGRect] { controls.frames }

    private let drawing = OverlayPanel(interactive: false)
    private let controls = ControlPanels()
    private let view: PillView
    private let clock: () -> TimeInterval
    /// Fires when the listening time gains a digit, so the pill widens for it.
    private var widening: Timer?
    /// When the pill last began to drop in, on `clock`: its controls wait from then (`OverlayLifecycle.controlsWait`).
    private var droppedAt = -Double.infinity
    /// Fires when a control that is waiting may take clicks.
    private var controlsWait: Timer?
    private var lifecycle = OverlayLifecycle()
    private var screenNumber: UInt32?
    private var appearance: PillAppearance
    /// The part of the screen the drawing panel covers, in screen points; it only grows while the pill is up.
    private var canvas: CGRect?
    private var announced: UInt64?
    private var observers: [any NSObjectProtocol] = []

    /// `levels` is the feed the audio path writes to; `clock` is the monotonic clock its times, and the displays'
    /// start times, are on (the session's).
    public init(levels: LevelFeed, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        view = PillView(levels: levels, clock: clock)
        self.clock = clock
        appearance = Self.systemAppearance()
        drawing.contentView = view
        view.onRest = { [weak self] in self?.rested() }
        controls.onPress = { [weak self] kind in self?.view.pressed = kind }
        controls.onActivate = { [weak self] kind in self?.activate(kind) }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appearanceChanged() }
        })
    }

    isolated deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        drawing.orderOut(nil)
        controls.hide()
        widening?.invalidate()
        controlsWait?.invalidate()
    }

    /// Shows `display`: the pill drops down from the band, changes form, or goes back up, on its spring.
    public func show(_ display: PillDisplay) {
        guard display != self.display else { return }
        self.display = display
        // A press on a control that is about to change belongs to nothing any more.
        view.pressed = nil
        guard let step = lifecycle.show(display) else { return }
        if step.drops { droppedAt = clock() }
        if step.chooseScreen, let screen = Self.chooseScreen() {
            let moving = drawing.isVisible && screen.displayNumber != screenNumber
            if moving {
                // A new dictation on another screen: the pill leaves this one and drops down on that one, where its
                // controls wait for it again.
                drawing.orderOut(nil)
                view.reset()
                droppedAt = clock()
            }
            if moving || !drawing.isVisible {
                screenNumber = screen.displayNumber
                topology = ScreenTopology(screen)
                canvas = nil
            }
        }
        refresh(animated: true)
        announce(display)
    }

    // MARK: - Placing the panels

    private func refresh(animated: Bool) {
        guard let topology else { return }
        var elapsed = 0.0
        if case .listening(let listening) = display { elapsed = clock() - listening.started }
        let scene = PillScene(display: display, screen: topology, elapsed: elapsed)
        let rest = PillGeometry.layout(.rest, on: topology)
        place(covering: [rest.body.frame, scene.layout.body.frame, scene.layout.cancel ?? rest.body.frame,
                         view.scene?.layout.body.frame ?? rest.body.frame], on: topology)
        view.update(scene, appearance: appearance, animated: animated)
        // Hiding may have come to rest at once; then the panel stays off the screen.
        if lifecycle.phase == .up, !drawing.isVisible { drawing.orderFrontRegardless() }
        placeControls()
        widenWhenTheTimeGainsADigit(after: elapsed)
    }

    /// Puts the controls of what the pill shows on the screen, each once it may take clicks; while the pill is not up,
    /// none.
    private func placeControls() {
        controlsWait?.invalidate()
        controlsWait = nil
        guard let topology, let scene = view.scene, lifecycle.phase == .up else { return controls.hide() }
        let now = clock()
        let from = scene.controls.map { droppedAt + OverlayLifecycle.controlsWait($0.kind) }
        controls.show(zip(scene.controls, from).filter { $0.1 <= now }.map(\.0)) { self.global($0, on: topology) }
        guard let next = from.filter({ $0 > now }).min() else { return }
        let timer = Timer(timeInterval: next - now, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeControls() }
        }
        RunLoop.main.add(timer, forMode: .common)
        controlsWait = timer
    }

    /// While listening, refreshes the pill at the moment its time gains a digit, so it widens for it on its spring.
    private func widenWhenTheTimeGainsADigit(after elapsed: TimeInterval) {
        widening?.invalidate()
        widening = nil
        guard lifecycle.phase == .up, case .listening = display else { return }
        // A moment after the digit arrives, so the clock read then is past it.
        let wait = PillScene.timeGainsADigit(after: elapsed) - elapsed + 0.005
        let timer = Timer(timeInterval: max(wait, 0.005), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(animated: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        widening = timer
    }

    /// Sizes the drawing panel to cover `frames` and room around them for the spring's give and the edge, growing it
    /// if it is already up.
    private func place(covering frames: [CGRect], on screen: ScreenTopology) {
        var wanted = frames.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -24, dy: -16)
        wanted = wanted.intersection(CGRect(x: 0, y: 0, width: screen.width, height: screen.height))
        // Window frames land on whole points, so the canvas does too, and the pill is drawn from where the panel
        // really is, so its edges land on the pixels the geometry chose.
        wanted = CGRect(x: wanted.minX.rounded(.down), y: wanted.minY.rounded(.down),
                        width: wanted.maxX.rounded(.up) - wanted.minX.rounded(.down),
                        height: wanted.maxY.rounded(.up) - wanted.minY.rounded(.down))
        let next = canvas.map { $0.union(wanted) } ?? wanted
        guard next != canvas, !next.isEmpty else { return }
        canvas = next
        drawing.setFrame(global(next, on: screen), display: false)
        let placed = drawing.frame
        view.frame = CGRect(origin: .zero, size: placed.size)
        view.origin = CGPoint(x: placed.minX - screen.frame.minX, y: screen.frame.maxY - placed.maxY)
    }

    /// A rectangle in `screen`'s points (top left, y down) in global window coordinates.
    private func global(_ rect: CGRect, on screen: ScreenTopology) -> CGRect {
        CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width,
               height: rect.height)
    }

    /// The pill has gone back up to its rest and faded: its panels leave the screen.
    private func rested() {
        guard lifecycle.rested() else { return }
        drawing.orderOut(nil)
        controls.hide()
        canvas = nil
    }

    // MARK: - Events

    private func activate(_ kind: PillControl.Kind) {
        view.pressed = nil
        switch kind {
        case .stop: onStop()
        case .cancel: onCancel()
        case .action(let notice, let id): onNoticeAction(notice, id)
        }
    }

    private func announce(_ display: PillDisplay) {
        guard case .notice(let notice) = display, notice.id != announced else { return }
        announced = notice.id
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: notice.text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func screensChanged() {
        guard lifecycle.appliesChanges else { return }
        let screen = NSScreen.screens.first { $0.displayNumber == screenNumber } ?? NSScreen.main
        guard let screen else { return }
        let next = ScreenTopology(screen)
        guard next != topology || screen.displayNumber != screenNumber else { return }
        screenNumber = screen.displayNumber
        topology = next
        canvas = nil
        refresh(animated: false)
    }

    private func appearanceChanged() {
        let next = Self.systemAppearance()
        guard next != appearance else { return }
        appearance = next
        if lifecycle.appliesChanges { refresh(animated: false) }
    }

    private static func systemAppearance() -> PillAppearance {
        let workspace = NSWorkspace.shared
        return PillAppearance(reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                              increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
    }

    /// The screen with keyboard focus, failing that the one under the pointer.
    private static func chooseScreen() -> NSScreen? {
        if let main = NSScreen.main { return main }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.screens.first
    }
}
