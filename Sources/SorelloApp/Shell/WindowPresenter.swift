import AppKit
import DesignCore
import SorelloUI
import SwiftUI

/// A window of Sorello's in the sense of ARCHITECTURE.md, section 8, "Windows": while one is open, Sorello is an
/// ordinary app with a Dock icon. The pill, the Accessibility card and alerts are not among them.
enum AppWindow: Hashable {
    case setup
    case main
    /// Transcribe File.
    case transcribe
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
}

/// An app other than Sorello that has been in front, as the presenter needs to know it to hand the front back.
/// `NSRunningApplication` is one; a test gives its own.
@MainActor
protocol FrontApp: AnyObject {
    var processIdentifier: pid_t { get }
    /// Whether it is an ordinary app, with a Dock icon, rather than an agent such as the one that shows the system's
    /// own prompts.
    var isOrdinary: Bool { get }
    /// Whether it has quit.
    var isTerminated: Bool { get }
    /// Asks for it to be in front, with the front handed over by Sorello.
    func takeFront()
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

}

extension NSRunningApplication: FrontApp {
    @MainActor var isOrdinary: Bool { activationPolicy == .regular }

    /// Cooperative activation, as Apple documents it: Sorello first lets the app make itself active, then asks for it
    /// to be activated from Sorello. Either may be refused; then Sorello simply stays in front.
    @MainActor func takeFront() {
        NSApp.yieldActivation(to: self)
        _ = activate(from: .current)
    }
}

/// The app's windows: the main window, setup, Transcribe File and the notices' text. Each is made once and kept while
/// the app runs.
/// The presenter knows which are open, from the first time each is shown until it closes, by whatever means: its
/// close button, ⌘W or Close in the Window menu, or Done in setup. A minimised window is still open. Sorello is in the
/// Dock exactly while one is open (ARCHITECTURE.md, section 8, "Windows").
@MainActor
final class WindowPresenter {
    private let dock: any DockPresence
    private var made: [AppWindow: NSWindow] = [:]
    /// The open windows, the one most recently in front last.
    private(set) var open: [AppWindow] = []
    /// The latest ordinary app other than Sorello to have been in front: the one to hand the front back to.
    private var previous: (any FrontApp)?
    private var observers: [any NSObjectProtocol] = []
    /// Hears each window close, by whatever means, after the presenter has counted it closed.
    var onClose: (AppWindow) -> Void = { _ in }

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

    /// Brings Transcribe File forward, opening it if it is closed.
    func showTranscribe(_ model: TranscribeModel, title: String) {
        show(.transcribe) { Self.transcribeWindow(model, title: title) }
    }

    /// Shows the full text of a notice, one window per notice.
    func showNotice(title: String, files: [URL]) {
        show(.notice(title)) { Self.noticeWindow(title: title, files: files) }
    }

    /// Clicking the Dock icon, or opening Sorello again: the open windows come forward, minimised ones out of the
    /// Dock, in the order they were last in front, so the one in front before is in front again. With none open, the
    /// main window opens.
    func reopen(main model: MainWindowModel, title: String) {
        guard isInDock else { return showMain(model, section: nil, title: title) }
        dock.activate()
        for id in open {
            if let window = made[id] { dock.bringForward(window) }
        }
    }

    /// Brings `window` in front again if it is still open, as after the system's microphone prompt, which leaves
    /// whatever it likes in front. A window that was closed meanwhile stays closed.
    func bringBack(_ id: AppWindow) {
        guard isOpen(id), let window = made[id] else { return }
        dock.activate()
        dock.bringForward(window)
        markInFront(id)
    }

    /// Hears that `app` has come to the front. Sorello itself, and agents such as the one that shows the system's
    /// prompts, are not remembered, so the front only ever goes back to an ordinary app the user was in.
    func appCameToFront(_ app: any FrontApp) {
        guard app.isOrdinary, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previous = app
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

    /// Hears `window` close, and become key when the user clicks it, for as long as the presenter keeps it.
    private func watch(_ window: NSWindow, as id: AppWindow) -> NSWindow {
        made[id] = window
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                            queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed(id) }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                            queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen(id) else { return }
                self.markInFront(id)
            }
        })
        return window
    }

    /// The last window to close makes Sorello a menu-bar app again and, if it was in front, asks for the app that was
    /// in front before it to come forward, if that app is still running. Sorello never hides itself to give up the
    /// front, since that would hide the pill as well. With no such app, or when the system refuses the request, it
    /// stays in front, without a window, until the user clicks elsewhere. A window that closes while another app is in
    /// front leaves the front where it is.
    ///
    /// This runs while the window is closing (`willCloseNotification`; AppKit offers no notice once a close is done,
    /// and waiting for a later turn would be a guess at timing). Apple's documentation of `setActivationPolicy` and
    /// of closing a window sets no order between them, and the policy is the app's Dock icon, app switcher entry and
    /// menu bar, nothing the closing window holds. Handing over the front is a request the other app acts on later,
    /// not something done to the closing window. When Sorello quits, AppKit closes every window, so this runs then
    /// too, which is harmless: the front goes where it would go anyway.
    private func closed(_ id: AppWindow) {
        guard isOpen(id) else { return }
        open.removeAll { $0 == id }
        onClose(id)
        guard !isInDock else { return }
        dock.leaveDock()
        guard dock.isActive, let previous, !previous.isTerminated else { return }
        previous.takeFront()
    }

    /// The main window as the app builds it, not yet on screen.
    static func mainWindow(_ model: MainWindowModel, title: String) -> NSWindow {
        window(.main, title: title, content: MainWindowView(model: model))
    }

    /// Setup's window as the app builds it, not yet on screen.
    static func setupWindow(_ model: SetupModel, title: String) -> NSWindow {
        window(.setup, title: title, content: SetupView(model: model))
    }

    /// Transcribe File's window as the app builds it, not yet on screen.
    static func transcribeWindow(_ model: TranscribeModel, title: String) -> NSWindow {
        window(.transcribe, title: title, content: TranscribeView(model: model))
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

/// The app's menus, in the menu bar while Sorello is an ordinary app and in front, as it is while one of its windows
/// is open (ARCHITECTURE.md, section 8, "Windows"): its own, Edit and Window, as a small Mac app has them and no
/// more. Every row sends a standard action up the responder chain, or to the shell for About, Settings and Quit, so
/// AppKit enables each row where it can act and disables it where it cannot, as it does in any app. Their key
/// equivalents work in the app's windows: without Edit, ⌘V would not paste into setup's test field.
@MainActor
enum MainMenu {
    /// The menu bar's menus, and the Window menu among them, which the app gives AppKit as its Window menu so that
    /// AppKit lists the open windows at its foot. `target` receives About, Settings and Quit.
    static func make(appName: String, target: AnyObject?) -> (bar: NSMenu, window: NSMenu) {
        let bar = NSMenu()

        let app = NSMenu(title: appName)
        app.addItem(item(String(localized: "About \(appName)"), #selector(AppShell.showAbout(_:)), "", target))
        app.addItem(.separator())
        app.addItem(item(String(localized: "Settings…"), #selector(AppShell.showSettings(_:)), ",", target))
        app.addItem(.separator())
        app.addItem(item(String(localized: "Hide \(appName)"), #selector(NSApplication.hide(_:)), "h", nil))
        let hideOthers = item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)),
                              "h", nil)
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(hideOthers)
        app.addItem(item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:)), "", nil))
        app.addItem(.separator())
        app.addItem(item(String(localized: "Quit \(appName)"), #selector(AppShell.quit(_:)), "q", target))
        add(app, to: bar)

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
        add(edit, to: bar)

        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", nil))
        window.addItem(item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:)), "", nil))
        window.addItem(item(String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w", nil))
        window.addItem(.separator())
        window.addItem(item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)), "",
                            nil))
        add(window, to: bar)
        return (bar, window)
    }

    /// The menus as text, for review in place of a picture only the system can draw while a window is open: each
    /// menu's title, then its rows, indented, each with its key equivalent at the end, aligned with spaces.
    static func text(of bar: NSMenu) -> String {
        bar.items.compactMap(\.submenu).map { menu in
            let rows = menu.items.map { item in
                item.isSeparatorItem ? ("separator", "") : (item.title, keyEquivalentLabel(item))
            }
            let width = rows.map(\.0.count).max() ?? 0
            let lines = rows.map { title, keys in
                keys.isEmpty ? "  " + title
                    : "  " + title + String(repeating: " ", count: width + 2 - title.count) + keys
            }
            return ([menu.title] + lines).joined(separator: "\n") + "\n"
        }.joined(separator: "\n")
    }

    private static func keyEquivalentLabel(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let mask = item.keyEquivalentModifierMask
        let modifiers = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { mask.contains($0.0) }.map(\.1).joined()
        return modifiers + item.keyEquivalent.uppercased()
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
