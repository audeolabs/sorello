import AppKit
import Foundation
import SorelloUI
import Testing
@testable import SorelloApp

/// ARCHITECTURE.md, section 8, "Windows": the main window and setup have the sizes their chrome gives them, and what
/// a window shows never changes them; a notice's window keeps its opening size and its own minimum. Each window is
/// built by the function the app builds it with and is never put on the screen.
@MainActor
@Suite struct WindowSizeTests {
    /// A window needs an application, and the app's fonts decide how tall its text is. Neither may be left to another
    /// suite that happens to run first.
    init() {
        _ = NSApplication.shared
        Resources.registerFonts()
    }

    /// The size a window's content is now, as `setContentSize` would set it.
    private func contentSize(of window: NSWindow) -> CGSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    /// Lets the main run loop turn, as it does between anything the user sees, and lays the window out. What a hosting
    /// view asks of its window is applied only then, so a size read before it proves nothing.
    private func settle(_ window: NSWindow) async {
        try? await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
    }

    /// Records an issue, naming `where`, unless `window` has its chrome's default size and minimum.
    private func expectChrome(_ window: NSWindow, _ kind: WindowChrome.Kind, at place: String,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(contentSize(of: window) == kind.defaultSize, "size at \(place)", sourceLocation: sourceLocation)
        #expect(window.contentMinSize == kind.minimumSize, "minimum at \(place)", sourceLocation: sourceLocation)
    }

    // MARK: Setup

    /// Each change setup goes through, in the order a person meets them, forward to the end and back to the start,
    /// with every state that changes what a step shows.
    private static let setupChanges: [(String, @MainActor (SetupModel) -> Void)] = [
        ("welcome", { $0.step = .welcome }),
        ("microphone not asked", { $0.step = .microphone; $0.microphone = .notDetermined }),
        ("microphone denied", { $0.microphone = .denied }),
        ("microphone granted", { $0.microphone = .granted }),
        ("accessibility missing", { $0.step = .accessibility; $0.accessibility = .missing }),
        ("accessibility granted", { $0.accessibility = .granted }),
        ("shortcut", { $0.step = .shortcut }),
        ("test, model preparing", { $0.step = .test; $0.model = .preparing }),
        ("test, model ready", { $0.model = .ready }),
        ("test, model missing", { $0.model = .failed(.missing) }),
        ("test, model damaged", { $0.model = .failed(.damaged) }),
        ("test, model could not load", { $0.model = .failed(.couldNotLoad) }),
        ("test, several lines", {
            $0.model = .ready
            $0.testText = Array(repeating: "Pack my box with five dozen liquor jugs, then carry it up the hill.",
                                count: 8).joined(separator: "\n")
        }),
        ("back to shortcut", { $0.step = .shortcut }),
        ("back to accessibility", { $0.step = .accessibility }),
        ("back to microphone", { $0.step = .microphone }),
        ("back to welcome", { $0.step = .welcome }),
    ]

    @Test func setupKeepsItsSizeAtEveryStepAndInEveryState() async {
        let model = SetupModel.sample(step: .welcome)
        let window = WindowPresenter.setupWindow(model, title: "Sorello")
        defer { window.close() }
        #expect(!window.styleMask.contains(.resizable))
        expectChrome(window, .setup, at: "opening")
        for (place, change) in Self.setupChanges {
            change(model)
            await settle(window)
            expectChrome(window, .setup, at: place)
        }
    }

    // MARK: Main window

    @Test func theMainWindowOpensAtItsSizeAndKeepsItsMinimumAtEverySection() async {
        let model = MainWindowModel.sample(section: .general)
        let window = WindowPresenter.mainWindow(model, title: "Sorello")
        defer { window.close() }
        #expect(window.styleMask.contains(.resizable))
        expectChrome(window, .main, at: "opening")
        for section in MainSection.allCases {
            model.section = section
            await settle(window)
            expectChrome(window, .main, at: "\(section)")
        }
    }

    // MARK: Notices

    @Test(arguments: [true, false])
    func aNoticeKeepsItsOpeningSizeAndItsMinimum(withText: Bool) async throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appendingPathComponent("NOTICE.txt")
        let line = "Permission is granted to read these invented words, which wrap and wrap and wrap again, freely."
        try Array(repeating: line, count: 200).joined(separator: "\n").write(to: file, atomically: true,
                                                                              encoding: .utf8)
        let window = WindowPresenter.noticeWindow(title: "Invented Notice", files: withText ? [file] : [])
        defer { window.close() }
        await settle(window)
        #expect(contentSize(of: window) == WindowPresenter.noticeSize)
        #expect(window.contentMinSize == WindowPresenter.noticeMinimumSize)
    }
}
