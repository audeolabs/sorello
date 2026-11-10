import DesignCore
import Foundation

/// When the overlay's panels come and go, and when it chooses a screen (ARCHITECTURE.md, section 8, "The pill"). A
/// pure value so the sequencing can be tested without putting a window on the screen.
///
/// The pill appears on the screen with keyboard focus when a dictation starts and stays there for that dictation:
/// its wait and the notices after it. A new dictation chooses again, even if the pill never left the screen in
/// between. Once hidden, the panels stay on the screen only until the pill has come to rest; after that nothing (a
/// change of screens or of accessibility settings) brings them back until something is shown.
struct OverlayLifecycle: Equatable {
    enum Phase: Equatable {
        /// The panels are off the screen.
        case off
        /// Something is shown.
        case up
        /// Hidden, and still going back up or fading away.
        case leaving
    }

    /// What the overlay should do for one display.
    struct Step: Equatable {
        /// Read the screen with keyboard focus and put the pill there.
        var chooseScreen: Bool
        /// The panels must be on the screen.
        var present: Bool
        /// The pill was not up: it drops in, and its controls wait until it has (`controlsWait`).
        var drops = false
    }

    /// How long after a drop begins a control takes clicks, so a click never lands on a control that is not drawn
    /// yet: Stop and a notice's actions once the body has dropped into place and what it holds has arrived, Cancel
    /// once its bud has budded off and reached its place beside the pill. A pill that moves to another screen for a
    /// new dictation drops in there afresh, and its controls wait again.
    static func controlsWait(_ kind: PillControl.Kind) -> TimeInterval {
        if case .cancel = kind { return Motion.drop + Motion.bud.response }
        return Motion.drop + Motion.arrival
    }

    private(set) var phase = Phase.off
    /// The dictation the screen was chosen for, by its start time.
    private var dictation: TimeInterval?

    /// The step for showing `display`; nil when there is nothing to do (hiding a pill that is not up).
    mutating func show(_ display: PillDisplay) -> Step? {
        guard display != .hidden else {
            guard phase == .up else { return nil }
            phase = .leaving
            return Step(chooseScreen: false, present: false)
        }
        var choose = phase == .off
        if case .listening(let listening) = display, listening.started != dictation {
            dictation = listening.started
            choose = true
        }
        let drops = phase != .up
        phase = .up
        return Step(chooseScreen: choose, present: true, drops: drops)
    }

    /// The pill came to rest. True when its panels should leave the screen: it was hidden and nothing has been shown
    /// since.
    mutating func rested() -> Bool {
        guard phase == .leaving else { return false }
        phase = .off
        return true
    }

    /// Changes to the screen or the accessibility settings are drawn only while the panels are up.
    var appliesChanges: Bool { phase != .off }
}
