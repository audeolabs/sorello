import Foundation
import Persistence
import Testing

@Suite struct AppPathsTests {
    @Test func resolvesApplicationSupportForTheBundle() throws {
        let paths = try AppPaths(bundleIdentifier: "com.example.synthetic")
        #expect(paths.root.lastPathComponent == "com.example.synthetic")
        #expect(paths.root.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    @Test func namesEverySubPathInsideTheRoot() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/synthetic/root", isDirectory: true))
        #expect(paths.macrosFile.path == "/synthetic/root/macros.json")
        #expect(paths.dictionaryFile.path == "/synthetic/root/dictionary.json")
        #expect(paths.historyDirectory.path == "/synthetic/root/history")
        #expect(paths.modelsDirectory.path == "/synthetic/root/Models")
    }

    @Test(arguments: ["", ".", "..", "com/example", "../escape", "a\0b"])
    func refusesAnIdentifierThatIsNotOneName(identifier: String) {
        #expect(throws: AppPathsError.invalidBundleIdentifier) { try AppPaths(bundleIdentifier: identifier) }
    }

    /// From outside the app, as the `sorello` command finds an app's data: the same root, under the directory given,
    /// and the same refusals.
    @Test func resolvesUnderAGivenApplicationSupport() throws {
        let support = URL(fileURLWithPath: "/synthetic/Application Support", isDirectory: true)
        let paths = try AppPaths(bundleIdentifier: "com.example.synthetic", applicationSupport: support)
        #expect(paths.root.path == "/synthetic/Application Support/com.example.synthetic")
        #expect(try AppPaths(bundleIdentifier: "com.example.synthetic").root.lastPathComponent == "com.example.synthetic")
        for identifier in ["", ".", "..", "com/example", "a\0b"] {
            #expect(throws: AppPathsError.invalidBundleIdentifier) {
                try AppPaths(bundleIdentifier: identifier, applicationSupport: support)
            }
        }
    }

    @Test func prepareMakesTheRootOwnerOnly() throws {
        let temporary = try TemporaryDirectory()
        let paths = AppPaths(root: temporary.url.appendingPathComponent("com.example.synthetic", isDirectory: true))
        try paths.prepare()
        #expect(try permissions(of: paths.root) == 0o700)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.root.path)
        try paths.prepare()
        #expect(try permissions(of: paths.root) == 0o700)
        #expect(temporary.contents() == ["com.example.synthetic"])
    }
}
