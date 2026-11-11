import Foundation
import SorelloUI
import Testing
@testable import SorelloApp

/// About acknowledges the display face (ARCHITECTURE.md, section 8) and opens the licence that ships beside it.
@MainActor
@Suite struct AboutTests {
    @Test func aboutNamesUrbanistAndOpensItsLicence() throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let app = directory.url.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"),
                                                withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.dictation", "CFBundleName": "Example",
                                    "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))

        // The app points at the licence in its own Fonts directory, which the build copies from the repository's.
        let bundle = try #require(Bundle(url: app))
        let licence = try #require(AppInfo(bundle: bundle).fontLicence)
        #expect(Array(licence.pathComponents.suffix(2)) == ["Fonts", "Urbanist-OFL.txt"])
        let shipped = try #require(Resources.directory).appendingPathComponent("Fonts/Urbanist-OFL.txt")
        #expect(FileManager.default.fileExists(atPath: shipped.path))

        let harness = Harness(directory: directory.url, defaults: suite.defaults, fontLicence: licence)
        let notices = harness.windows.main.about.thirdPartyNotices
        let notice = try #require(notices.first { $0.title == "Urbanist" })
        #expect(notice.detail.contains("The Urbanist Project Authors"))
        #expect(notice.detail.contains("SIL Open Font License 1.1"))
        #expect(notices.map(\.id) == [notice.id, "permission-card", "sparkle"],
                "a notice for work the app does not ship, or none for work it does")

        let shown = ShownNotices()
        harness.app.navigation.showNotice = { shown.notices.append(($0, $1)) }
        harness.windows.main.about.showNotice(notice.id)
        #expect(shown.notices.map(\.title) == ["Urbanist"])
        #expect(shown.notices.first?.files == [licence])
    }

    /// Sparkle ships in every build's Frameworks directory, whether or not the build has an update feed, so About
    /// credits it in every build and opens the notices file that carries its licence.
    @Test func aboutCreditsSparkleAndOpensItsLicence() throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let notices = directory.url.appendingPathComponent("Example.app/Contents/Resources/ThirdPartyNotices.md")
        let harness = Harness(directory: directory.url, defaults: suite.defaults, thirdPartyNotices: notices)
        let notice = try #require(harness.windows.main.about.thirdPartyNotices.first { $0.id == "sparkle" })
        #expect(notice.title == "Sparkle")
        #expect(notice.detail.contains("MIT License"))

        let shown = ShownNotices()
        harness.app.navigation.showNotice = { shown.notices.append(($0, $1)) }
        harness.windows.main.about.showNotice(notice.id)
        #expect(shown.notices.map(\.title) == ["Sparkle"])
        #expect(shown.notices.first?.files == [notices], "the notices file the app carries, which holds the licence")
        // The notices file the build copies into every app carries Sparkle's licence and the notices it requires.
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let shipped = try String(contentsOf: repository.appendingPathComponent("ThirdPartyNotices.md"), encoding: .utf8)
        for part in ["## Sparkle", "Copyright (c) 2006-2013 Andy Matuschak.", "Colin Percival", "Yuta Mori",
                     "Orson Peters", "Mark Hamlin"] {
            #expect(shipped.contains(part), "\(part)")
        }
    }
}

/// The notices the windows asked the shell to show.
@MainActor
private final class ShownNotices {
    var notices: [(title: String, files: [URL])] = []
}
