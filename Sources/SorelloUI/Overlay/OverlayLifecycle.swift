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
        /// How long the controls wait before they take clicks: appearing, until the pill has dropped into place and
        /// what it holds has arrived, so a click never lands on a control that is not drawn yet.
        var controlsAfter: TimeInterval = 0
    }

    /// How long the controls of a pill that is appearing wait.
    static let arrival = Motion.drop + Motion.arrival

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
        let appearing = phase != .up
        phase = .up
        return Step(chooseScreen: choose, present: true, controlsAfter: appearing ? Self.arrival : 0)
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
