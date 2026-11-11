import Foundation
import SorelloUI
import Testing
@testable import SorelloApp

/// ARCHITECTURE.md, sections 6 ("Updates"), 8 (the menu) and 11: what the app shows of its updater and what each part
/// asks of it, through `Updating` and a fake. No test here starts Sparkle or opens a connection.
@MainActor
@Suite struct UpdatesTests {
    // MARK: Which builds have an updater

    @Test func aBuildWithoutAFeedGetsNoUpdater() {
        var made = 0
        let info = AppInfo(name: "Sorello Dev", version: "0.0.1", build: "1")
        let updater = Updates.updater(for: info) { _ in
            made += 1
            return FakeUpdater()
        }
        #expect(updater == nil)
        #expect(made == 0, "Sparkle would have been made, and so could have been started")
    }

    @Test func aBuildWithAFeedGetsOne() throws {
        let feed = try #require(URL(string: "https://example.com/appcast.xml"))
        let info = AppInfo(name: "Sorello Nightly", version: "0.0.1", build: "7", updateFeed: feed)
        var given: AppInfo?
        let fake = FakeUpdater()
        let updater = Updates.updater(for: info) {
            given = $0
            return fake
        }
        #expect(updater === fake)
        #expect(given == info)
    }

    /// The feed is the one in the bundle's Info.plist, and only an app bundle's counts.
    @Test func theFeedIsReadFromTheAppsInfoPlist() throws {
        let directory = try TemporaryDirectory()
        func app(_ name: String, feed: String?) throws -> AppInfo {
            let app = directory.url.appendingPathComponent("\(name).app", isDirectory: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"),
                                                    withIntermediateDirectories: true)
            var plist: [String: Any] = ["CFBundleIdentifier": "com.example.\(name)", "CFBundleName": name,
                                        "CFBundlePackageType": "APPL"]
            plist["SUFeedURL"] = feed
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            return AppInfo(bundle: try #require(Bundle(url: app)))
        }
        #expect(try app("Fed", feed: "https://example.com/feed/appcast.xml").updateFeed
                == URL(string: "https://example.com/feed/appcast.xml"))
        #expect(try app("Unfed", feed: nil).updateFeed == nil)
    }

    // MARK: A build with no updater

    @Test func withoutAnUpdaterNothingShowsUpdates() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        harness.app.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.windows.menu.updates == nil)
        #expect(!harness.windows.menu.rows.contains { $0.command == .checkForUpdates })
        #expect(harness.windows.main.general.offersUpdates == false)
        #expect(harness.windows.main.general.toggles[.checkForUpdates] == nil)
        // The row's action has nothing to ask.
        harness.windows.menu.actions.perform(.checkForUpdates)
    }

    // MARK: A build with an updater

    @Test func theUpdaterStartsWithTheAppOnce() throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let updater = FakeUpdater()
        let harness = Harness(directory: directory.url, defaults: suite.defaults, updater: updater)
        #expect(updater.starts == 0, "nothing starts until the app does")
        harness.app.start()
        harness.app.start()
        #expect(updater.starts == 1)
    }

    /// A feed address left in the preferences is removed at launch, before the updater could read it.
    @Test func aFeedLeftInThePreferencesIsRemovedBeforeTheUpdaterStarts() throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        suite.defaults.set("https://example.com/elsewhere.xml", forKey: "SUFeedURL")
        let updater = FakeUpdater()
        var seenAtStart: String? = "not started"
        updater.onStart = { seenAtStart = suite.defaults.string(forKey: "SUFeedURL") }
        let harness = Harness(directory: directory.url, defaults: suite.defaults, updater: updater)
        harness.app.start()
        #expect(seenAtStart == nil)
        #expect(suite.defaults.object(forKey: "SUFeedURL") == nil)
    }

    @Test func theMenuFollowsTheUpdater() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let updater = FakeUpdater()
        let harness = Harness(directory: directory.url, defaults: suite.defaults, updater: updater)
        let menu = harness.windows.menu
        harness.app.start()
        await eventually { menu.updates == .checkForUpdates(isEnabled: true) }
        #expect(menu.rows.contains { $0.command == .checkForUpdates && $0.title == "Check for Updates…" })

        updater.canCheck = false
        await eventually { menu.updates == .checkForUpdates(isEnabled: false) }

        // A check made on its own found a version: the row says so, and nothing else was asked of the updater.
        updater.canCheck = true
        updater.foundUnseen = true
        await eventually { menu.updates == .updateAvailable }
        #expect(menu.rows.contains { $0.title == "Update Available…" && $0.isEnabled })
        #expect(updater.checks == 0, "a version found unasked shows no window by itself")

        // Seen, installed or skipped: back to the command.
        updater.foundUnseen = false
        await eventually { menu.updates == .checkForUpdates(isEnabled: true) }
    }

    /// Either form of the row asks the updater for its window, once per choice.
    @Test func choosingTheRowAsksTheUpdaterForItsWindow() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let updater = FakeUpdater()
        let harness = Harness(directory: directory.url, defaults: suite.defaults, updater: updater)
        harness.app.start()
        harness.windows.menu.actions.perform(.checkForUpdates)
        #expect(updater.checks == 1)
        updater.foundUnseen = true
        await eventually { harness.windows.menu.updates == .updateAvailable }
        harness.windows.menu.actions.perform(.checkForUpdates)
        #expect(updater.checks == 2)
    }

    /// General has the switch, showing the updater's choice, and flipping it changes only that.
    @Test func generalsSwitchIsTheUpdatersDailyCheck() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let updater = FakeUpdater()
        let harness = Harness(directory: directory.url, defaults: suite.defaults, updater: updater)
        let general = harness.windows.main.general
        harness.app.start()
        #expect(general.offersUpdates)
        await eventually { general.toggles[.checkForUpdates] == true }

        let before = GeneralBindingSnapshot(harness)
        general.actions.setToggle(.checkForUpdates, false)
        #expect(updater.checksAutomatically == false)
        await eventually { general.toggles[.checkForUpdates] == false }
        #expect(GeneralBindingSnapshot(harness) == before, "no other setting changed")
        #expect(updater.checks == 0, "turning the daily check off or on checks nothing now")

        general.actions.setToggle(.checkForUpdates, true)
        #expect(updater.checksAutomatically)
        await eventually { general.toggles[.checkForUpdates] == true }
    }

    // MARK: The self-test

    /// `--self-test --update <feed>` takes one http or https address and nothing else.
    @Test func theUpdateSelfTestTakesOneFeed() throws {
        let feed = try #require(URL(string: "http://127.0.0.1:8000/appcast.xml"))
        #expect(LaunchMode(arguments: ["--self-test", "--update", feed.absoluteString]) == .updateTest(feed: feed))
        #expect(LaunchMode(arguments: ["--self-test", "--update", "https://example.com/a.xml"])
                == .updateTest(feed: try #require(URL(string: "https://example.com/a.xml"))))
        for arguments in [["--self-test", "--update"], ["--self-test", "--update", "file:///tmp/appcast.xml"],
                          ["--self-test", "--update", "appcast.xml"],
                          ["--self-test", "--update", feed.absoluteString, "a.wav"],
                          ["--self-test", "--update", feed.absoluteString, "--cpu"]] {
            #expect(LaunchMode(arguments: arguments) == .usage(LaunchMode.usage), "\(arguments)")
        }
        #expect(LaunchMode(arguments: ["--update", feed.absoluteString]) == .app(showsSetup: true),
                "the app itself cannot be pointed at another feed")
        #expect(LaunchMode.usage.contains("--self-test --update <feed-url>"))
    }
}

/// The General switches other than the update check, to see that flipping it changes none of them.
@MainActor
private struct GeneralBindingSnapshot: Equatable {
    let toggles: [GeneralToggle: Bool]

    init(_ harness: Harness) {
        toggles = harness.windows.main.general.toggles.filter { $0.key != .checkForUpdates }
    }
}
