import AppKit
import DesignCore
import SorelloUI
import SwiftUI

/// The app's windows: the main window, setup and the notices' text. Each is made once, kept while the app runs, and
/// brought forward with the app activated, which an app with no Dock icon has to ask for.
@MainActor
struct WindowPresenter {
    private var main: NSWindow?
    private var setup: NSWindow?
    private var notices: [String: NSWindow] = [:]

    /// Shows the main window, at `section` if given and otherwise at the section it last showed.
    mutating func showMain(_ model: MainWindowModel, section: MainSection?, title: String) {
        if let section { model.section = section }
        let window = main ?? Self.mainWindow(model, title: title)
        main = window
        Self.bringForward(window)
    }

    mutating func showSetup(_ model: SetupModel, title: String) {
        let window = setup ?? Self.setupWindow(model, title: title)
        setup = window
        Self.bringForward(window)
    }

    func closeSetup() {
        setup?.close()
    }

    /// Shows the full text of a notice, one window per notice.
    mutating func showNotice(title: String, files: [URL]) {
        let window = notices[title] ?? Self.noticeWindow(title: title, files: files)
        notices[title] = window
        Self.bringForward(window)
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
        window.contentView = NSHostingView(rootView: NoticeText(title: title, text: text))
        window.center()
        return window
    }

    private static func window(_ kind: WindowChrome.Kind, title: String, content: some View) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: kind.defaultSize), styleMask: [.titled],
                              backing: .buffered, defer: true)
        WindowChrome.apply(to: window, kind: kind)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.preferredColorScheme(.dark))
        window.setContentSize(kind.defaultSize)
        window.center()
        return window
    }

    private static func bringForward(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
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

/// The app's menu. It is never shown, because the app has no Dock icon, but its key equivalents work in the app's
/// windows: Quit, Close, Settings, and the Edit commands, without which ⌘V would not paste into setup's test field.
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
