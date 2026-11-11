import DictationCore
import Foundation
import Persistence
import SorelloUI
import Testing
@testable import SorelloApp

/// Run Log retries through the whole graph (ARCHITECTURE.md, section 7, "Run Log"): a retry replaces an entry's words,
/// pastes nothing, and leaves what the entry says about how it ended true.
@MainActor
@Suite struct RunLogRetryTests {
    /// A running app that has taken one dictation, heard as `transcript`, into the Run Log.
    private func dictated(_ transcript: String, pressEnterCommand: Bool, in directory: URL,
                          defaults: UserDefaults) async -> Harness {
        let harness = Harness(directory: directory, defaults: defaults)
        harness.app.settings.pressEnterCommand = pressEnterCommand
        harness.speech.transcript = transcript
        harness.app.start()
        await eventually { harness.app.runtime.state.engine == .ready }
        await harness.dictate()
        await eventually { harness.windows.main.runLog.items.count == 1 }
        return harness
    }

    /// Retries the only entry, hearing `transcript` this time, and waits for the retry to end.
    private func retry(_ harness: Harness, hearing transcript: String) async throws {
        let id = try #require(harness.windows.main.runLog.items.first?.id)
        harness.speech.retried = transcript
        harness.windows.main.runLog.actions.retry(id)
        await eventually { harness.app.live.retryingIDs.isEmpty }
    }

    @Test func aRetryReplacesTheWordsAndPastesNothing() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = await dictated("hello world", pressEnterCommand: false, in: directory.url,
                                     defaults: suite.defaults)
        try await retry(harness, hearing: "pack my box")

        let expected = TextRulesSnapshot(settings: harness.app.settings, macros: [])
            .process("pack my box", style: .plain, context: nil)
        await eventually { harness.windows.main.runLog.items.first?.text == expected.text }
        let item = try #require(harness.windows.main.runLog.items.first)
        #expect(item.heard == "pack my box")
        #expect(item.outcomeLabel == RunLogOutcome.inserted.label)
        #expect(harness.inserter.composed.count == 1, "Only the dictation itself reached the inserter")
    }

    @Test func aRetryThatHearsOnlyACommandLeavesPastedWordsAsTheyWere() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        // With the command off, "press enter" is words like any others, and they were pasted.
        let harness = await dictated("press enter", pressEnterCommand: false, in: directory.url,
                                     defaults: suite.defaults)
        let before = try #require(harness.app.history.entries.first)
        #expect(!before.text.isEmpty)
        #expect(RunLogItem(before).outcomeLabel == RunLogOutcome.inserted.label)

        // The command is switched on, so the same words are now only a command. Nothing pressed Return, and the
        // row must not say that something did.
        harness.app.settings.pressEnterCommand = true
        try await retry(harness, hearing: "press enter")
        #expect(harness.speech.retries == 1)
        #expect(harness.app.history.entries == [before])
        #expect(harness.windows.main.runLog.items.first?.outcomeLabel == RunLogOutcome.inserted.label)
        #expect(harness.inserter.composed.count == 1, "A retry pastes nothing and presses no key")
    }

    @Test func aRetryThatHearsWordsLeavesACommandAsItWas() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = await dictated("press enter", pressEnterCommand: true, in: directory.url,
                                     defaults: suite.defaults)
        let before = try #require(harness.app.history.entries.first)
        #expect(RunLogItem(before).display == .commandOnly(heard: "press enter"))
        #expect(RunLogItem(before).outcomeLabel == "Return pressed")

        // Nothing was pasted, so words heard now must not be shown as if they had been.
        try await retry(harness, hearing: "pack my box")
        #expect(harness.speech.retries == 1)
        #expect(harness.app.history.entries == [before])
        #expect(harness.windows.main.runLog.items.first?.outcomeLabel == "Return pressed")
        #expect(harness.inserter.composed.count == 1, "A retry pastes nothing and presses no key")
    }
}
