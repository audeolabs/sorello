import AppKit
import Foundation

/// `Sorello --self-test --update <feed>` (ARCHITECTURE.md, section 11): the packaged app's own updater, against the
/// feed given and with the key in the app, for this run only. It prints one line per fact, shows no window, and exits
/// 0 when the feed was read and either offered nothing newer or offered a newer build that downloaded and verified,
/// which the installer then puts in place of this app as the command ends, without opening it. Anything else exits 1.
/// It is run on a copy of the app, against a feed on the same Mac that lists a build signed for the test.
@MainActor
enum UpdateSelfTest {
    static func run(feed: URL) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let info = AppInfo.main()
        Console.line("\(info.name) \(info.version) (\(info.build)) self-test, updates from \(feed.absoluteString)")
        guard info.bundleIdentifier != nil, info.updateFeed != nil else {
            Console.line("update: failed: this build has no update feed, so it has no updater to test")
            Console.line("self-test FAILED")
            exit(1)
        }
        Task {
            let passed = await SparkleUpdateTest.run(feed: feed, info: info, report: Console.line)
            Console.line(passed ? "self-test passed" : "self-test FAILED")
            exit(passed ? 0 : 1)
        }
        application.run()
        exit(1)
    }
}
