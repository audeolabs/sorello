import AppKit
import SorelloUI

/// The menu-bar item and its menu (ARCHITECTURE.md, section 8, "Windows"). The item is the mark's row as a template
/// image. Its menu is an ordinary menu, which the system opens, tracks and closes; SorelloUI makes its items from the
/// menu's values.
@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private let menu: StatusMenuController

    init(model: StatusMenuModel, appName: String) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = StatusMenuController(model: model)
        if let button = item.button {
            button.image = SorelloMarkImages.menuBarIcon()
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(appName)
        }
        item.menu = menu.menu
    }

    isolated deinit {
        NSStatusBar.system.removeStatusItem(item)
    }

    /// Closes the menu if it is open, as the app quits.
    func close() {
        menu.menu.cancelTracking()
    }
}
