import AppKit
import DesignCore
import SorelloUI
import SwiftUI

/// The menu-bar item and its panel (ARCHITECTURE.md, section 8, "Windows"). The item is the mark's row as a template
/// image. A click opens the menu panel under it, as a menu opens: a rounded, shadowed panel on the screen colour that
/// closes on a click elsewhere, on Escape, when an item is chosen or when the app goes to the background.
@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let panel: MenuPanelWindow
    private let model: MenuPanelModel
    private var outsideClicks: Any?
    private var keys: Any?
    private var resignObserver: (any NSObjectProtocol)?

    init(model: MenuPanelModel, appName: String) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = MenuPanelWindow()
        super.init()
        if let button = item.button {
            button.image = SorelloMarkImages.menuBarIcon()
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(appName)
            button.target = self
            button.action = #selector(toggle(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        // Choosing a way into the app closes the panel first, as choosing a menu item does. Copy keeps it open to
        // show that it copied.
        let actions = model.actions
        model.actions = MenuPanelActions(
            copyLastDictation: actions.copyLastDictation, retryModel: actions.retryModel,
            openGeneral: { [weak self] in self?.close(); actions.openGeneral() },
            openDictionary: { [weak self] in self?.close(); actions.openDictionary() },
            openRunLog: { [weak self] in self?.close(); actions.openRunLog() },
            openSettings: { [weak self] in self?.close(); actions.openSettings() },
            quit: { [weak self] in self?.close(); actions.quit() })
        panel.contentView = MenuPanelWindow.surface(for: MenuPanelView(model: model))
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    isolated deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        stopMonitoring()
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func toggle(_ sender: Any?) {
        panel.isVisible ? close() : open()
    }

    private func open() {
        guard let button = item.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        let size = panel.contentView?.fittingSize ?? CGSize(width: WindowChrome.menuPanelWidth, height: 360)
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - 5 - size.height)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - size.width - 6)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        startMonitoring()
    }

    /// Closes the panel if it is open.
    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        item.button?.highlight(false)
        stopMonitoring()
    }

    private func startMonitoring() {
        stopMonitoring()
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
    }

    private func stopMonitoring() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let keys { NSEvent.removeMonitor(keys) }
        outsideClicks = nil
        keys = nil
    }
}

/// The menu panel's window: borderless, above other windows like a menu, and able to take the keyboard for ⌘, and
/// ⌘Q without making the app's other windows key.
final class MenuPanelWindow: NSPanel {
    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: WindowChrome.menuPanelWidth, height: 360),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }

    /// The panel's content on the screen colour, with the rounded corners and hairline edge of a menu.
    static func surface(for content: some View) -> NSView {
        let hosting = NSHostingView(rootView: content.preferredColorScheme(.dark))
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        hosting.layer?.borderWidth = 0.5
        hosting.layer?.borderColor = NSColor(Palette.edge, alpha: 0.6).cgColor
        hosting.layer?.backgroundColor = NSColor(Palette.screen).cgColor
        return hosting
    }
}
