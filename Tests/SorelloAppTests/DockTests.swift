import AppKit
import Foundation
import SorelloUI
import Testing
@testable import SorelloApp

/// What the presenter asked AppKit to do, in order, with each window named. Nothing is done: no window goes on screen
/// and the test process's activation policy never changes.
@MainActor
final class RecordingDock: DockPresence {
    /// Whether Sorello is the active app, as the test says.
    var isActive = true
    private(set) var calls: [String] = []
    /// Names a window the presenter hands over; set once the presenter exists.
    var name: (NSWindow) -> String = { _ in "?" }

    func enterDock() { calls.append("enter Dock") }
    func leaveDock() { calls.append("leave Dock") }
    func activate() { calls.append("activate") }
    func bringForward(_ window: NSWindow) { calls.append("front \(name(window))") }
    func yieldFront(closing: NSWindow) { calls.append("yield front, closing \(name(closing))") }

    /// The calls since the last time they were taken.
    func take() -> [String] {
        defer { calls = [] }
        return calls
    }
}

/// ARCHITECTURE.md, section 8, "Windows": Sorello is in the Dock exactly while setup, the main window or a notice's
/// window is open. Each window is the one the app builds; the AppKit calls that would put it on screen are recorded
/// instead.
@MainActor
@Suite struct DockTests {
    let dock = RecordingDock()
    let presenter: WindowPresenter
    let main = MainWindowModel.sample(section: .general)
    let setup = SetupModel.sample(step: .welcome)

    init() {
        _ = NSApplication.shared
        Resources.registerFonts()
        presenter = WindowPresenter(dock: dock)
        dock.name = { [presenter] window in
            let all: [AppWindow] = [.setup, .main, .notice("Licence"), .notice("Credits")]
            return all.first { presenter.window($0) === window }.map(Self.describe) ?? "unknown"
        }
    }

    private static func describe(_ window: AppWindow) -> String {
        switch window {
        case .setup: "setup"
        case .main: "main"
        case .notice(let title): "notice \(title)"
        }
    }

    private func showMain() { presenter.showMain(main, section: nil, title: "Sorello Test") }
    private func showSetup() { presenter.showSetup(setup, title: "Sorello Test") }
    private func showNotice(_ title: String) { presenter.showNotice(title: title, files: []) }

    /// Closes `window` as its close button and ⌘W do.
    private func clickClose(_ window: AppWindow) throws {
        try #require(presenter.window(window)).performClose(nil)
    }

    // MARK: Which windows are open

    @Test func theFirstWindowMakesSorelloAnOrdinaryAppThenBringsItInFrontThenTheWindow() {
        #expect(!presenter.isInDock)
        showMain()
        #expect(presenter.isInDock)
        #expect(dock.take() == ["enter Dock", "activate", "front main"])
    }

    @Test func aSecondWindowComesForwardWithoutEnteringTheDockAgain() {
        showMain()
        _ = dock.take()
        showNotice("Licence")
        #expect(dock.take() == ["activate", "front notice Licence"])
        #expect(presenter.isInDock)
    }

    @Test func whenOneOfTwoClosesSorelloStaysInTheDock() throws {
        showSetup()
        showNotice("Licence")
        _ = dock.take()
        try clickClose(.notice("Licence"))
        #expect(presenter.isInDock)
        #expect(dock.take() == [])
        #expect(presenter.isOpen(.setup))
        #expect(!presenter.isOpen(.notice("Licence")))
    }

    @Test func whenTheLastClosesSorelloLeavesTheDockAndTheAppBehindComesForward() throws {
        showMain()
        showNotice("Licence")
        try clickClose(.notice("Licence"))
        _ = dock.take()
        try clickClose(.main)
        #expect(!presenter.isInDock)
        #expect(dock.take() == ["leave Dock", "yield front, closing main"])
    }

    /// A window closed while another app is in front leaves that app in front.
    @Test func theLastClosingWhileAnotherAppIsInFrontLeavesTheFrontAlone() throws {
        showNotice("Licence")
        _ = dock.take()
        dock.isActive = false
        try clickClose(.notice("Licence"))
        #expect(!presenter.isInDock)
        #expect(dock.take() == ["leave Dock"])
    }

    @Test func doneClosesSetupAndSorelloLeavesTheDock() {
        showSetup()
        _ = dock.take()
        presenter.closeSetup()
        #expect(!presenter.isOpen(.setup))
        #expect(!presenter.isInDock)
        #expect(dock.take() == ["leave Dock", "yield front, closing setup"])
    }

    @Test func theMainWindowClosedByItsCloseButtonOrCommandW() throws {
        showMain()
        _ = dock.take()
        try clickClose(.main)
        #expect(!presenter.isInDock)
        #expect(dock.take() == ["leave Dock", "yield front, closing main"])
    }

    @Test func aNoticeClosedIsNoLongerOpen() throws {
        showNotice("Licence")
        showNotice("Credits")
        try clickClose(.notice("Credits"))
        #expect(presenter.open == [.notice("Licence")])
        try clickClose(.notice("Licence"))
        #expect(!presenter.isInDock)
    }

    /// Showing a window that is already open brings it forward and counts it once, so one close is its last.
    @Test func aWindowShownTwiceCountsOnce() throws {
        showMain()
        showMain()
        #expect(presenter.open == [.main])
        _ = dock.take()
        try clickClose(.main)
        #expect(!presenter.isInDock)
        #expect(dock.take() == ["leave Dock", "yield front, closing main"])
    }

    @Test func aWindowOpenedClosedAndOpenedAgainPutsSorelloBackInTheDock() throws {
        showSetup()
        presenter.closeSetup()
        _ = dock.take()
        showSetup()
        #expect(presenter.isInDock)
        #expect(dock.take() == ["enter Dock", "activate", "front setup"])
    }

    /// A minimised window is off the screen but still open, so Sorello stays in the Dock.
    @Test func aMinimisedWindowStillCounts() throws {
        showMain()
        let window = try #require(presenter.window(.main))
        window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        #expect(!window.isVisible)
        #expect(presenter.isInDock)
        #expect(presenter.isOpen(.main))
    }
}
