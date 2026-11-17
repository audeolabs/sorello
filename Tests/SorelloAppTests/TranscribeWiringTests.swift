import AppKit
import FileTranscription
import Foundation
import Persistence
import SorelloUI
import Testing
import TextRules
@testable import SorelloApp

/// ARCHITECTURE.md, section 8, "Windows", Transcribe, as the app wires it: the menu's row, the main window's opening
/// and closing, the app's text rules, its clipboard, its engine and its General screen. The transcriber is the fake engine's, which the test drives.
@MainActor
@Suite struct TranscribeWiringTests {
    let talk = URL(fileURLWithPath: "/tmp/invented/harbour talk.m4a")

    /// What the screen asked the shell to do.
    @MainActor
    final class Shell {
        /// How many times the main window was brought forward at Transcribe.
        var shown: Int { opened.filter { $0 == .transcribe }.count }
        var pickers: [@MainActor (URL) -> Void] = []
        var saved: [(String, String)] = []
        var opened: [MainSection?] = []
    }

    /// The shell's navigation, recorded, with the main window open as the menu's row opens it unless `opened` is
    /// false.
    private func wire(_ harness: Harness, opened: Bool = true) -> Shell {
        defer { if opened { harness.windows.transcribe.open() } }
        let shell = Shell()
        harness.app.navigation.chooseAudioFile = { shell.pickers.append($0) }
        harness.app.navigation.saveText = { shell.saved.append(($0, $1)) }
        harness.app.navigation.openMain = { shell.opened.append($0) }
        return shell
    }

    /// Transcribe File…, chosen in the menu the app builds, brings the main window forward at Transcribe and shows
    /// the picker; the file chosen goes to the app's engine.
    @Test func theMenuRowOpensTheMainWindowAtTranscribeAndThePicker() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        let shell = wire(harness, opened: false)
        let controller = StatusMenuController(model: harness.windows.menu)
        controller.menuNeedsUpdate(controller.menu)
        let row = try #require(controller.menu.items.firstIndex { $0.title == "Transcribe File…" })
        #expect(controller.menu.items[row].isEnabled)
        controller.menu.performActionForItem(at: row)
        #expect(shell.opened == [.transcribe] && shell.pickers.count == 1)

        let pick = try #require(shell.pickers.first)
        pick(talk)
        await eventually { harness.speech.files.all.count == 1 }
        #expect(harness.speech.files.last?.file == talk)

        // While it is being transcribed, the row only brings the window forward.
        controller.menu.performActionForItem(at: row)
        #expect(shell.opened == [.transcribe, .transcribe] && shell.pickers.count == 1)
    }

    /// The main window opened any other way (Settings…, the Dock) lets the screen take a file. Closing it stops the
    /// transcription and forgets the file; closing another window does not.
    @Test func theScreenBeginsAndEndsWithTheMainWindow() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        _ = wire(harness, opened: false)
        let windows = harness.windows, screen = harness.windows.transcribe.model
        windows.windowOpened(.setup)
        screen.actions.dropFile()(talk)
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.speech.files.all.isEmpty, "Only the main window's opening lets the screen take files")

        windows.windowOpened(.main)
        screen.actions.dropFile()(talk)
        await eventually { harness.speech.files.all.count == 1 }
        windows.windowClosed(.setup)
        windows.windowClosed(.notice("Licence"))
        #expect(screen.state == .transcribing(file: "harbour talk.m4a", read: 0, length: 0))
        #expect(harness.speech.files.last?.wasCancelled == false)
        windows.windowClosed(.main)
        #expect(screen.state == .empty)
        await eventually { harness.speech.files.last?.wasCancelled == true }
    }

    /// Going to another section leaves the screen as it is: a file dropped on the main window's Transcribe screen goes
    /// on being transcribed while General shows, its text is there on coming back, and closing the main window then
    /// forgets it.
    @Test func anotherSectionLeavesTheScreenAsItIs() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        _ = wire(harness, opened: false)
        let windows = harness.windows, main = harness.windows.main
        windows.windowOpened(.main)
        main.section = .transcribe
        main.transcribe.actions.dropFile()(talk)
        await eventually { harness.speech.files.all.count == 1 }
        main.section = .general
        harness.speech.files.last?.finish(.success("Invented words."))
        let done = TranscribeState.done(file: "harbour talk.m4a", text: "Invented words.")
        await eventually { main.transcribe.state == done }
        main.section = .transcribe
        #expect(main.transcribe.state == done)
        #expect(harness.speech.files.last?.wasCancelled == false)
        #expect(harness.speech.files.all.count == 1)

        windows.windowClosed(.main)
        #expect(main.transcribe.state == .empty)
    }

    /// The text rules are the app's: its settings and macros as they are when the transcription starts.
    @Test func theRulesAreTheAppsAsTheTranscriptionStarts() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        _ = wire(harness)
        let app = harness.app
        app.settings.spokenNumbers = false
        app.settings.pressEnterCommand = true
        let macro = try app.macros.add(command: "sign off", text: "Warm regards")
        harness.windows.transcribe.model.actions.dropFile()(talk)
        await eventually { harness.speech.files.all.count == 1 }
        let expected = TextRuleOptions(macros: [macro], pressEnterCommand: true, spokenNumbers: false,
                                       spokenDelimiters: app.settings.spokenDelimiters,
                                       promptTag: app.settings.promptTag)
        #expect(harness.speech.files.last?.rules == expected)
        #expect(harness.speech.files.last?.rules == TextRulesSnapshot(settings: app.settings, macros: app.macros.macros).options)
    }

    @Test func copyUsesTheAppsClipboardAndSaveTheShellsPanel() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        let shell = wire(harness)
        let window = harness.windows.transcribe
        window.model.actions.dropFile()(talk)
        await eventually { harness.speech.files.all.count == 1 }
        harness.speech.files.last?.finish(.success("Invented words."))
        await eventually { window.model.state == .done(file: "harbour talk.m4a", text: "Invented words.") }
        window.model.actions.copy()
        window.model.actions.save()
        #expect(harness.system.copied == ["Invented words."])
        #expect(shell.saved.map(\.0) == ["Invented words."] && shell.saved.map(\.1) == ["harbour talk.txt"])
        // The menu never shows it.
        #expect(harness.windows.menu.rows.allSatisfy { !$0.title.contains("Invented") })
    }

    @Test func downloadOpensGeneralAndRetryPreparesTheAppsEngine() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        let shell = wire(harness)
        let window = harness.windows.transcribe
        window.model.actions.dropFile()(talk)
        await eventually { harness.speech.files.all.count == 1 }
        harness.speech.files.last?.finish(.failure(.modelMissing))
        await eventually { window.model.state == .failed(file: "harbour talk.m4a", reason: .modelMissing) }
        window.model.actions.download()
        #expect(shell.opened == [.transcribe, .general], "Opened at Transcribe, then at General")

        let prepares = harness.speech.prepares
        window.model.actions.retry()
        await eventually { harness.speech.files.all.count == 2 }
        #expect(harness.speech.prepares == prepares + 1)
    }

    /// The engine is asked for its file transcriber once, told whether a model fits this Mac.
    @Test func theAppAsksItsEngineForTheTranscriber() throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        #expect(harness.speech.fileTranscribersMade == [true])
    }

    /// The app quitting stops a file being transcribed.
    @Test func quittingStopsTheTranscription() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        _ = wire(harness)
        harness.windows.transcribe.model.actions.dropFile()(talk)
        await eventually { harness.speech.files.all.count == 1 }
        harness.windows.stop()
        await eventually { harness.speech.files.last?.wasCancelled == true }
        #expect(harness.windows.transcribe.model.state == .empty)
    }
}

/// ARCHITECTURE.md, section 8, "Windows": a file opened with Sorello opens the main window at Transcribe with it, and one whose
/// opening launched the app waits until the app's ordinary launch has run.
@Suite struct OpenedFilesTests {
    let talk = URL(fileURLWithPath: "/tmp/invented/talk.m4a")
    let other = URL(fileURLWithPath: "/tmp/invented/other.wav")

    @Test func aFileOpenedBeforeTheLaunchHasFinishedWaitsForIt() {
        var files = OpenedFiles()
        #expect(files.opened([talk]) == nil)
        #expect(files.opened([other]) == nil, "Only the first waits")
        #expect(files.launched() == talk)
        #expect(files.launched() == nil)
    }

    @Test func afterTheLaunchAFileGoesStraightThrough() {
        var files = OpenedFiles()
        #expect(files.launched() == nil)
        #expect(files.opened([talk, other]) == talk, "The screen takes one file at a time")
        #expect(files.opened([other]) == other)
    }

    @Test func anOpeningWithoutAFileIsIgnored() throws {
        var files = OpenedFiles()
        _ = files.launched()
        #expect(files.opened([]) == nil)
        #expect(files.opened([try #require(URL(string: "https://example.com/talk.m4a"))]) == nil)
    }
}
