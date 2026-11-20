import AppKit
@testable import SorelloUI
import Testing

/// ARCHITECTURE.md, section 14, "Marks": how the ink overlay's window behaves on a display without touch and on one
/// with it. Nothing here puts a window on the screen.
@MainActor
@Suite struct InkOverlayTests {
    static let frame = CGRect(x: 0, y: 0, width: 400, height: 300)

    /// On a display without touch nothing changes: the overlay takes nothing and is over everything, an open menu
    /// included.
    @Test func withoutTouchTheOverlayTakesNothingAndIsOverEverything() {
        let panel = InkOverlayController.panel(over: Self.frame, takingFingers: false)
        #expect(panel.ignoresMouseEvents)
        #expect(panel.level == .screenSaver)
        #expect(panel.level.rawValue > NSWindow.Level.popUpMenu.rawValue)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.sharingType == .none)
    }

    /// Taking fingers, it is left to take what lands on its fill, and it sits under the pill's controls, so a finger
    /// can press them.
    @Test func takingFingersTheOverlaySitsJustUnderThePillsControls() {
        let panel = InkOverlayController.panel(over: Self.frame, takingFingers: true)
        let controls = OverlayPanel(interactive: true)
        #expect(!panel.ignoresMouseEvents)
        #expect(panel.level.rawValue == controls.level.rawValue - 1)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.sharingType == .none)
    }
}
