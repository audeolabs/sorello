import AppKit
@testable import SorelloUI
import Testing

/// ARCHITECTURE.md, section 14, "Marks": how the ink overlay's window behaves on a display without touch and on one
/// with it. Nothing here puts a window on the screen.
@MainActor
@Suite struct InkOverlayTests {
    static let frame = CGRect(x: 0, y: 0, width: 400, height: 300)

    /// The overlay that draws the ink takes nothing, on any display, and is over everything, an open menu included: ink
    /// under the pointer never takes its clicks.
    @Test func theInkTakesNothingAndIsOverEverything() {
        let panel = InkOverlayController.inkPanel(over: Self.frame)
        #expect(panel.ignoresMouseEvents)
        #expect(panel.level == .screenSaver)
        #expect(panel.level.rawValue > NSWindow.Level.popUpMenu.rawValue)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.sharingType == .none)
    }

    /// On a touch screen the catcher is left to take what lands on its fill, and it sits under the pill's controls, so a
    /// finger can press them, and under menus.
    @Test func theCatcherSitsJustUnderThePillsControlsAndUnderMenus() {
        let panel = InkOverlayController.catcherPanel(over: Self.frame)
        let controls = OverlayPanel(interactive: true)
        #expect(!panel.ignoresMouseEvents)
        #expect(panel.level.rawValue == controls.level.rawValue - 1)
        #expect(panel.level.rawValue < NSWindow.Level.popUpMenu.rawValue)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.sharingType == .none)
    }
}
