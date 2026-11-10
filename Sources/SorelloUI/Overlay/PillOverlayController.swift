import AppKit
import DesignCore

/// Puts the pill on the screen (ARCHITECTURE.md, section 8, "The pill"). It draws in one panel that ignores the mouse,
/// and offers the pill's controls (stop, cancel, a notice's actions) in a second panel exactly the size of those
/// controls, shown only while there are any, so the pill never swallows a click meant for the menu bar. Neither panel
/// takes keyboard focus.
///
/// The screen is chosen when the pill appears: the one with keyboard focus, else the one under the pointer. It is
/// kept until the pill hides; if it goes away the pill moves to the main screen. Reduce Motion and Increase Contrast
/// are read from the system and followed as they change. VoiceOver hears each notice once, and the controls as
/// buttons; the moving level is never exposed to it.
@MainActor
public final class PillOverlayController {
    /// The user clicked the pill while it listens in toggle mode, or pressed it with VoiceOver.
    public var onStop: () -> Void = {}
    /// The user clicked the cancel button that buds off the pill in toggle mode.
    public var onCancel: () -> Void = {}
    /// The user clicked an action of the notice with that id.
    public var onNoticeAction: (_ notice: UInt64, _ action: String) -> Void = { _, _ in }

    /// The two hidden nudges for the island pill. Applied at once.
    public var adjustments = PillAdjustments() {
        didSet { if adjustments != oldValue { refresh(animated: false) } }
    }

    /// What the pill shows now.
    public private(set) var display = PillDisplay.hidden
    /// The screen the pill is on, as it was read; nil while it has never been shown.
    public private(set) var topology: ScreenTopology?
    /// Where the pill's parts are for what it shows now, in the screen's points (top left, y down).
    public var layout: PillLayout? { view.scene?.layout }
    /// The panels' frames in global coordinates while they are on screen.
    public var drawingFrame: CGRect? { drawing.isVisible ? drawing.frame : nil }
    public var controlsFrame: CGRect? { controls.isVisible ? controls.frame : nil }

    private let drawing = OverlayPanel(interactive: false)
    private let controls = OverlayPanel(interactive: true)
    private let view: PillView
    private let controlsView = PillControlsView()
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
        appearance = Self.systemAppearance()
        drawing.contentView = view
        controls.contentView = controlsView
        view.onRest = { [weak self] in self?.rested() }
        controlsView.onPress = { [weak self] kind in self?.view.pressed = kind }
        controlsView.onActivate = { [weak self] kind in self?.activate(kind) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appearanceChanged() }
        })
    }

    deinit {
        MainActor.assumeIsolated {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            drawing.orderOut(nil)
            controls.orderOut(nil)
        }
    }

    /// Shows `display`: the pill grows, changes form or shrinks away on its spring.
    public func show(_ display: PillDisplay) {
        guard display != self.display else { return }
        let appearing = self.display == .hidden && !drawing.isVisible
        self.display = display
        if display == .hidden, !drawing.isVisible { return }
        if appearing {
            guard let screen = Self.chooseScreen() else { return }
            screenNumber = screen.displayNumber
            topology = ScreenTopology(screen)
            canvas = nil
        }
        refresh(animated: true)
        announce(display)
    }

    // MARK: - Placing the panels

    private func refresh(animated: Bool) {
        guard let topology else { return }
        let scene = PillScene(display: display, screen: topology, adjustments: adjustments)
        let rest = PillGeometry.layout(.rest, on: topology, adjustments: adjustments)
        place(covering: [rest.body.frame, scene.layout.body.frame, scene.layout.cancel ?? rest.body.frame,
                         view.scene?.layout.body.frame ?? rest.body.frame], on: topology)
        view.update(display: display, screen: topology, adjustments: adjustments, appearance: appearance,
                    animated: animated && drawing.isVisible)
        if !drawing.isVisible { drawing.orderFrontRegardless() }
        placeControls(scene.controls, on: topology)
    }

    /// Sizes the drawing panel to cover `frames` and room around them for the spring's give and the edge, growing it
    /// if it is already up.
    private func place(covering frames: [CGRect], on screen: ScreenTopology) {
        var wanted = frames.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -24, dy: -16)
        wanted = wanted.intersection(CGRect(x: 0, y: 0, width: screen.width, height: screen.height))
        if wanted.minY > 0 { wanted = CGRect(x: wanted.minX, y: 0, width: wanted.width, height: wanted.maxY) }
        let next = canvas.map { $0.union(wanted) } ?? wanted
        guard next != canvas, !next.isEmpty else { return }
        canvas = next
        drawing.setFrame(global(next, on: screen), display: false)
        view.frame = CGRect(origin: .zero, size: next.size)
        view.origin = next.origin
    }

    private func placeControls(_ list: [PillControl], on screen: ScreenTopology) {
        guard !list.isEmpty else {
            controls.orderOut(nil)
            return
        }
        let union = list.reduce(CGRect.null) { $0.union($1.frame) }
        controls.setFrame(global(union, on: screen), display: false)
        controlsView.frame = CGRect(origin: .zero, size: union.size)
        controlsView.show(list, origin: union.origin)
        controls.orderFrontRegardless()
    }

    /// A rectangle in `screen`'s points (top left, y down) in global window coordinates.
    private func global(_ rect: CGRect, on screen: ScreenTopology) -> CGRect {
        CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width,
               height: rect.height)
    }

    /// The pill has shrunk back into its housing (or faded): its panels leave the screen.
    private func rested() {
        guard display == .hidden else { return }
        drawing.orderOut(nil)
        controls.orderOut(nil)
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
        guard drawing.isVisible else { return }
        let screen = NSScreen.screens.first { $0.displayNumber == screenNumber } ?? NSScreen.main
        guard let screen else { return }
        let next = ScreenTopology(screen)
        guard next != topology else { return }
        screenNumber = screen.displayNumber
        topology = next
        canvas = nil
        refresh(animated: false)
    }

    private func appearanceChanged() {
        let next = Self.systemAppearance()
        guard next != appearance else { return }
        appearance = next
        refresh(animated: false)
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
