import AppKit
import DictationCore
import Foundation
import SorelloUI
import Synchronization
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

    // MARK: The Dock icon, and opening Sorello again

    @Test func withNoWindowOpenTheDockIconOpensTheMainWindow() {
        presenter.reopen(main: main, title: "Sorello Test")
        #expect(presenter.isOpen(.main))
        #expect(dock.take() == ["enter Dock", "activate", "front main"])
    }

    /// With setup open, the Dock icon brings setup forward and opens nothing else.
    @Test func withAWindowOpenTheDockIconBringsItForwardAndOpensNothingElse() {
        showSetup()
        _ = dock.take()
        presenter.reopen(main: main, title: "Sorello Test")
        #expect(presenter.open == [.setup])
        #expect(presenter.window(.main) == nil)
        #expect(dock.take() == ["activate", "front setup"])
    }

    /// Every open window comes forward, in the order they were last in front, so the one the user last had in front,
    /// by clicking it or by opening it, is in front again.
    @Test func theDockIconBringsEveryOpenWindowForwardInTheOrderTheyWereInFront() throws {
        showMain()
        showNotice("Licence")
        showNotice("Credits")
        let clicked: NSWindow = try #require(presenter.window(.main))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: clicked)
        _ = dock.take()
        presenter.reopen(main: main, title: "Sorello Test")
        #expect(dock.take() == ["activate", "front notice Licence", "front notice Credits", "front main"])
    }

    /// A minimised window comes out of the Dock: the presenter hands it to the same call as any other, which takes a
    /// minimised window out of the Dock.
    @Test func theDockIconBringsAMinimisedWindowForward() throws {
        showMain()
        try #require(presenter.window(.main)).orderOut(nil)
        _ = dock.take()
        presenter.reopen(main: main, title: "Sorello Test")
        #expect(dock.take() == ["activate", "front main"])
    }

    // MARK: After the microphone's prompt

    @Test func theWindowThatAskedComesBackInFront() {
        showMain()
        showSetup()
        _ = dock.take()
        presenter.bringBack(.setup)
        #expect(dock.take() == ["activate", "front setup"])
    }

    @Test func aWindowClosedDuringThePromptStaysClosed() {
        showSetup()
        presenter.closeSetup()
        _ = dock.take()
        presenter.bringBack(.setup)
        #expect(!presenter.isInDock)
        #expect(dock.take() == [])
    }
}

/// A microphone that has never been asked for, whose prompt waits for the test to answer it.
final class AskingMicrophone: MicrophoneAuthorizing {
    private struct State {
        var access = MicrophoneAccess.unknown
        var requests = 0
        var waiting: [CheckedContinuation<MicrophoneAccess, Never>] = []
    }

    private let state = Mutex(State())

    func current() -> MicrophoneAccess { state.withLock { $0.access } }

    func request() async -> MicrophoneAccess {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                state.requests += 1
                state.waiting.append(continuation)
            }
        }
    }

    var requests: Int { state.withLock { $0.requests } }

    /// Answers every prompt on screen with `access`.
    func answer(_ access: MicrophoneAccess) {
        let waiting = state.withLock { state in
            state.access = access
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume(returning: access) }
    }
}

/// ARCHITECTURE.md, section 8, "Windows": when a window asks for the microphone, that window is in front again once
/// the system's prompt has been answered; a dictation never brings Sorello forward.
@MainActor
@Suite struct MicrophonePromptTests {
    @Test(arguments: [AppWindow.setup, .main])
    func allowBringsTheWindowThatAskedBackOnceThePromptIsAnswered(_ window: AppWindow) async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let microphone = AskingMicrophone()
        let harness = Harness(directory: directory.url, defaults: suite.defaults, microphone: microphone)
        var broughtBack: [AppWindow] = []
        harness.app.navigation.bringBack = { broughtBack.append($0) }
        harness.app.start()

        if window == .setup {
            harness.windows.setup.actions.requestMicrophone()
        } else {
            harness.windows.main.general.actions.requestMicrophone()
        }
        await eventually { microphone.requests == 1 }
        #expect(broughtBack == [], "Not while the prompt is on screen")

        microphone.answer(.granted)
        await eventually { broughtBack == [window] }
        #expect(harness.app.runtime.state.microphone == .granted)
    }

    @Test func aDictationsOwnRequestBringsNothingForward() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let microphone = AskingMicrophone()
        let harness = Harness(directory: directory.url, defaults: suite.defaults, microphone: microphone)
        var asked: [String] = []
        harness.app.navigation.bringBack = { asked.append("bring back \($0)") }
        harness.app.navigation.openMain = { asked.append("open main \(String(describing: $0))") }
        harness.app.navigation.openSetup = { asked.append("open setup") }
        let app = harness.app
        app.start()
        await eventually { app.runtime.state.engine == .ready }

        app.relay.handle(.holdPressed, at: harness.clock.now)
        await eventually { microphone.requests == 1 }
        microphone.answer(.granted)
        await eventually { if case .recording = app.runtime.state.capture { true } else { false } }
        app.relay.handle(.holdReleased(.keyUp), at: harness.clock.now)
        await eventually { app.runtime.state.microphone == .granted && app.runtime.state.capture == .idle }
        #expect(asked == [])
    }
}
