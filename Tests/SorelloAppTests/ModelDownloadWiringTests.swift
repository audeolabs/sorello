import DictationCore
import DictionaryKit
import Foundation
import SorelloUI
import SpeechEngine
import Testing
@testable import SorelloApp

/// The model's download in the app (ARCHITECTURE.md, sections 5 and 8): what launch shows when the model is not on
/// the Mac, that only the two Download buttons start it, and what happens when it arrives. The download is a fake
/// that opens no connection.
@MainActor
@Suite struct ModelDownloadWiringTests {
    static let size: Int64 = 138_084_519

    /// The vocabulary a downloaded model brings.
    static func vocabulary(in directory: URL) throws -> BPEEncoder {
        try BPEEncoder(vocabularyFile: try makeModelDirectory(in: directory).appendingPathComponent("vocabulary.json"))
    }

    @Test func aModelThatCanBeDownloadedIsOfferedAndNothingStartsIt() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let download = FakeDownload(.absent)
        let harness = Harness(directory: directory.url, defaults: suite.defaults, download: download,
                              readiness: .failed(.modelMissing))
        harness.app.settings.setupCompleted = true
        harness.app.start()
        let expected = ModelStatus.notDownloaded(.notStarted(size: Self.size))
        #expect(await eventually {
            harness.windows.menu.status.model == expected && harness.windows.main.general.status.model == expected
        })
        #expect(harness.windows.menu.rows.first?.title == "Speech model not downloaded")
        #expect(harness.windows.menu.rows.dropFirst().first?.command == .openGeneral)
        // At launch an absent model that can be downloaded opens setup at its step, which this setup then has.
        #expect(harness.windows.setupIsNeeded)
        #expect(harness.windows.setupStartStep == .model)
        #expect(harness.windows.setupSteps == SetupStep.allCases)
        #expect(harness.windows.setup.modelSize == Self.size)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(download.starts == 0, "Nothing starts the download at launch")
    }

    @Test func aModelOnThisMacHasNoStep() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults, download: FakeDownload(.installed))
        harness.app.settings.setupCompleted = true
        harness.app.start()
        #expect(await eventually { harness.windows.status.model == .ready })
        #expect(!harness.windows.setupIsNeeded)
        #expect(harness.windows.setupSteps == SetupStep.steps(includingModel: false))
        #expect(harness.windows.setupStartStep == .welcome)
    }

    /// No build for this Mac: setup still has the step, which says so, but it is not opened for it.
    @Test func noBuildForThisMacIsSaidButNotOffered() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults, download: FakeDownload(.unavailable),
                              readiness: .failed(.modelMissing))
        harness.app.settings.setupCompleted = true
        harness.app.start()
        #expect(await eventually { harness.windows.status.model == .notDownloaded(.unavailable) })
        #expect(!harness.windows.setupIsNeeded)
        #expect(harness.windows.setupSteps == SetupStep.allCases)
    }

    /// The Download buttons in setup and on General start it, Cancel stops it, and the menu's command only opens
    /// General.
    @Test func onlyTheButtonsStartTheDownload() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let download = FakeDownload(.absent)
        let harness = Harness(directory: directory.url, defaults: suite.defaults, download: download,
                              readiness: .failed(.modelMissing))
        var opened: [MainSection?] = []
        harness.app.navigation.openMain = { opened.append($0) }
        harness.app.start()
        harness.windows.menu.actions.perform(.openGeneral)
        #expect(opened == [.general])
        #expect(download.starts == 0)
        harness.windows.setup.actions.downloadModel()
        #expect(download.starts == 1)
        harness.windows.main.general.actions.downloadModel()
        #expect(download.starts == 2)
        harness.windows.main.general.actions.cancelDownload()
        #expect(download.cancels == 1)
    }

    /// While it downloads every window says how much has arrived; once it has put the model in the store, the engine
    /// is asked to prepare and the dictionary takes the vocabulary, without a relaunch.
    @Test func whenTheModelArrivesTheEngineLooksAgainAndTheDictionaryOpens() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let download = FakeDownload(.absent, vocabulary: try Self.vocabulary(in: directory.url))
        let harness = Harness(directory: directory.url, defaults: suite.defaults, download: download,
                              readiness: .failed(.modelMissing))
        harness.app.start()
        #expect(await eventually { harness.app.runtime.state.engine == .failed(.modelMissing) })
        #expect(!harness.app.dictionary.canEdit)
        let prepares = harness.speech.prepares

        download.publish(.downloading(received: 62_400_000))
        #expect(await eventually {
            harness.windows.main.general.status.model
                == .notDownloaded(.downloading(received: 62_400_000, size: Self.size))
                && harness.windows.menu.rows.first?.title == "Downloading speech model"
        })
        download.publish(.failed(.server))
        #expect(await eventually {
            harness.windows.main.general.status.model == .notDownloaded(.failed(.server, size: Self.size))
        })
        #expect(harness.speech.prepares == prepares, "A download that failed changes nothing for the engine")

        harness.speech.afterPrepare = .ready
        download.publish(.installed)
        #expect(await eventually { harness.speech.prepares == prepares + 1 })
        #expect(await eventually { harness.app.runtime.state.engine == .ready })
        #expect(await eventually { harness.app.dictionary.canEdit }, "The dictionary can be changed once the model is here")
        #expect(await eventually { harness.windows.main.general.status.model == .ready })
    }

    /// The engine found the stored model missing (a damaged copy it removed): the download looks again, so it offers
    /// itself once more.
    @Test func aModelTheEngineCannotFindIsLookedForAgain() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let download = FakeDownload(.installed)
        let harness = Harness(directory: directory.url, defaults: suite.defaults, download: download)
        harness.app.start()
        #expect(await eventually { harness.app.runtime.state.engine == .ready })
        #expect(download.refreshes == 0)
        harness.speech.publish(.failed(.modelMissing))
        #expect(await eventually { download.refreshes >= 1 })
    }

    /// A dictation begun without the model ends in a notice that says it has not been downloaded.
    @Test func aDictationWithoutTheModelSaysItIsNotDownloaded() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults, download: FakeDownload(.absent),
                              readiness: .failed(.modelMissing))
        harness.app.start()
        #expect(await eventually { harness.app.runtime.state.engine == .failed(.modelMissing) })
        harness.app.relay.handle(.holdPressed, at: harness.clock.now)
        #expect(await eventually {
            harness.app.runtime.state.notice?.message.text == "The speech model isn’t downloaded yet"
        })
    }
}
