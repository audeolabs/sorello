import AppKit
import DesignCore
import SorelloUI
import SwiftUI

/// A window of Sorello's in the sense of ARCHITECTURE.md, section 8, "Windows": while one is open, Sorello is an
/// ordinary app with a Dock icon. The pill, the Accessibility card and alerts are not among them.
enum AppWindow: Hashable {
    case setup
    case main
    /// A notice's text, one window per notice, named by its title.
    case notice(String)
}

/// The few AppKit calls that carry out what `WindowPresenter` decides, and nothing else, so that tests can replace
/// them: a test never puts a window on screen or changes its own process's activation policy.
@MainActor
protocol DockPresence {
    /// Whether Sorello is the active app.
    var isActive: Bool { get }
    /// Makes Sorello an ordinary app: a Dock icon, a place in the app switcher, and its menus while it is in front.
    func enterDock()
    /// Makes Sorello a menu-bar app again: no Dock icon and no place in the app switcher.
    func leaveDock()
    /// Asks for Sorello to be the active app.
    func activate()
    /// Puts `window` in front of Sorello's other windows, out of the Dock if it was minimised, and makes it key.
    func bringForward(_ window: NSWindow)
    /// Gives the front to the app behind Sorello, leaving the pill and every panel of Sorello's where they are.
    /// `closing` is the window whose close made Sorello leave the Dock; it is still on screen while it closes.
    func yieldFront(closing: NSWindow)
}

/// `DockPresence` as AppKit does it.
struct SystemDock: DockPresence {
    var isActive: Bool { NSApp.isActive }

    func enterDock() { NSApp.setActivationPolicy(.regular) }

    func leaveDock() { NSApp.setActivationPolicy(.accessory) }

    func activate() { NSApp.activate() }

    func bringForward(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // Activation is a request the system may refuse; the window still comes to the front of its level.
        window.orderFrontRegardless()
    }

    func yieldFront(closing: NSWindow) {
        // Hiding is the documented way to give the front to "the next app in line", and an app without a Dock
        // icon would otherwise stay in front with no window. But a hidden app's panels stay hidden, and the pill
        // must appear for the next dictation without Sorello coming forward, so the hidden panels are put back at
        // once without activating Sorello. The closing window goes first, or it would be put back with them.
        closing.orderOut(nil)
        NSApp.hide(nil)
        NSApp.unhideWithoutActivation()
    }
}

/// The app's windows: the main window, setup and the notices' text. Each is made once and kept while the app runs.
/// The presenter knows which are open, from the first time each is shown until it closes, by whatever means: its
/// close button, ⌘W or Close in the Window menu, or Done in setup. A minimised window is still open. Sorello is in the
/// Dock exactly while one is open (ARCHITECTURE.md, section 8, "Windows").
@MainActor
final class WindowPresenter {
    private let dock: any DockPresence
    private var made: [AppWindow: NSWindow] = [:]
    /// The open windows, the one most recently in front last.
    private(set) var open: [AppWindow] = []
    private var observers: [any NSObjectProtocol] = []

    init(dock: any DockPresence) {
        self.dock = dock
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Whether Sorello is in the Dock: one of its windows is open.
    var isInDock: Bool { !open.isEmpty }

    /// Whether `window` is open, on screen or minimised.
    func isOpen(_ window: AppWindow) -> Bool { open.contains(window) }

    /// The window, once it has been made.
    func window(_ window: AppWindow) -> NSWindow? { made[window] }

    /// Shows the main window, at `section` if given and otherwise at the section it last showed.
    func showMain(_ model: MainWindowModel, section: MainSection?, title: String) {
        if let section { model.section = section }
        show(.main) { Self.mainWindow(model, title: title) }
    }

    func showSetup(_ model: SetupModel, title: String) {
        show(.setup) { Self.setupWindow(model, title: title) }
    }

    func closeSetup() {
        made[.setup]?.close()
    }

    /// Shows the full text of a notice, one window per notice.
    func showNotice(title: String, files: [URL]) {
        show(.notice(title)) { Self.noticeWindow(title: title, files: files) }
    }

    /// The first window to open makes Sorello an ordinary app before it activates, so the window comes forward the
    /// way any app's does; every window is then brought forward with the app active.
    private func show(_ id: AppWindow, make: () -> NSWindow) {
        let window = made[id] ?? watch(make(), as: id)
        if !isInDock { dock.enterDock() }
        dock.activate()
        dock.bringForward(window)
        markInFront(id)
    }

    private func markInFront(_ id: AppWindow) {
        open.removeAll { $0 == id }
        open.append(id)
    }

    /// Hears `window` close, for as long as the presenter keeps it.
    private func watch(_ window: NSWindow, as id: AppWindow) -> NSWindow {
        made[id] = window
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                            queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed(id) }
        })
        return window
    }

    /// The last window to close makes Sorello a menu-bar app again and, if it was in front, gives the front to the
    /// app behind it. One that was not in front leaves the front where it is.
    private func closed(_ id: AppWindow) {
        guard isOpen(id) else { return }
        open.removeAll { $0 == id }
        guard !isInDock else { return }
        dock.leaveDock()
        if dock.isActive, let window = made[id] { dock.yieldFront(closing: window) }
    }

    /// The main window as the app builds it, not yet on screen.
    static func mainWindow(_ model: MainWindowModel, title: String) -> NSWindow {
        window(.main, title: title, content: MainWindowView(model: model))
    }

    /// Setup's window as the app builds it, not yet on screen.
    static func setupWindow(_ model: SetupModel, title: String) -> NSWindow {
        window(.setup, title: title, content: SetupView(model: model))
    }

    /// The size a notice's window opens at.
    static let noticeSize = CGSize(width: 640, height: 560)
    /// The smallest a notice's window may be made.
    static let noticeMinimumSize = CGSize(width: 420, height: 320)

    /// A notice's window as the app builds it, not yet on screen: the text of `files`, one after another.
    static func noticeWindow(title: String, files: [URL]) -> NSWindow {
        let text = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n\n")
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: noticeSize),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(Palette.screen)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentMinSize = noticeMinimumSize
        window.contentView = content(NoticeText(title: title, text: text), size: noticeSize)
        window.center()
        return window
    }

    private static func window(_ kind: WindowChrome.Kind, title: String, content: some View) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: kind.defaultSize), styleMask: [.titled],
                              backing: .buffered, defer: true)
        WindowChrome.apply(to: window, kind: kind)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = Self.content(content.preferredColorScheme(.dark), size: kind.defaultSize)
        window.setContentSize(kind.defaultSize)
        window.center()
        return window
    }

    /// A window's content, `size` points, drawn by SwiftUI without setting the window's size or limits. A hosting view
    /// that is a window's content view sets the window's minimum and maximum from what it shows, and SwiftUI takes the
    /// smallest size with every line of text wrapped as narrow as it will go, which is very tall: setup, which cannot
    /// be made wider, grew taller than the screen and hid its buttons, and the main window could be made small enough
    /// to clip what it shows. So the hosting view sits inside a plain view that fills the window, follows its size
    /// and asks nothing of it.
    private static func content(_ view: some View, size: CGSize) -> NSView {
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        return container
    }
}

/// A notice's text, as it ships in the app: the licence or attribution, verbatim and selectable.
private struct NoticeText: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: title)
                    .displayType(.screenTitle)
                    .foregroundStyle(Theme.ink)
                Text(verbatim: text.isEmpty ? String(localized: "This notice is not in this copy of the app.") : text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.secondaryInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, Metrics.titleBarClearance + 8)
            .padding(.bottom, Metrics.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.screen)
        .preferredColorScheme(.dark)
    }
}

/// The app's menu, in the menu bar while Sorello is in front, which it can be only while one of its windows is open.
/// Its key equivalents work in the app's windows: Quit, Close, Settings, and the Edit commands, without which ⌘V would
/// not paste into setup's test field.
@MainActor
enum MainMenu {
    static func make(appName: String, target: AnyObject) -> NSMenu {
        let menu = NSMenu()

        let app = NSMenu(title: appName)
        app.addItem(item(String(localized: "About \(appName)"), #selector(AppShell.showAbout(_:)), "", target))
        app.addItem(.separator())
        app.addItem(item(String(localized: "Settings…"), #selector(AppShell.showSettings(_:)), ",", target))
        app.addItem(.separator())
        app.addItem(item(String(localized: "Hide \(appName)"), #selector(NSApplication.hide(_:)), "h", nil))
        app.addItem(item(String(localized: "Quit \(appName)"), #selector(AppShell.quit(_:)), "q", target))
        add(app, to: menu)

        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(item(String(localized: "Undo"), Selector(("undo:")), "z", nil))
        let redo = item(String(localized: "Redo"), Selector(("redo:")), "z", nil)
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x", nil))
        edit.addItem(item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c", nil))
        edit.addItem(item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v", nil))
        edit.addItem(item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a", nil))
        add(edit, to: menu)

        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(item(String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w", nil))
        window.addItem(item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", nil))
        add(window, to: menu)
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private static func add(_ submenu: NSMenu, to menu: NSMenu) {
        let holder = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        holder.submenu = submenu
        menu.addItem(holder)
    }
}
