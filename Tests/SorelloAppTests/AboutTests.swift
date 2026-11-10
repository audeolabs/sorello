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
        #expect(notices.map(\.id) == [notice.id, "permission-card"], "a notice for a font the app does not ship")

        let shown = ShownNotices()
        harness.app.navigation.showNotice = { shown.notices.append(($0, $1)) }
        harness.windows.main.about.showNotice(notice.id)
        #expect(shown.notices.map(\.title) == ["Urbanist"])
        #expect(shown.notices.first?.files == [licence])
    }
}

/// The notices the windows asked the shell to show.
@MainActor
private final class ShownNotices {
    var notices: [(title: String, files: [URL])] = []
}
