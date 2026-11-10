import DictationCore
import Foundation
import Testing
@testable import SorelloApp

@Suite struct LaunchModeTests {
    @Test func theAppIgnoresArgumentsItDoesNotKnow() {
        #expect(LaunchMode(arguments: []) == .app(showsSetup: true))
        #expect(LaunchMode(arguments: ["-NSDocumentRevisionsDebugMode", "YES"]) == .app(showsSetup: true))
        #expect(LaunchMode(arguments: ["--no-setup"]) == .app(showsSetup: false))
    }

    @Test func theSelfTestTakesFilesAndAModel() {
        #expect(LaunchMode(arguments: ["--self-test", "a.wav", "b.wav"])
                == .selfTest(files: [URL(fileURLWithPath: "a.wav"), URL(fileURLWithPath: "b.wav")], model: nil,
                             forcesCPU: false))
        #expect(LaunchMode(arguments: ["--self-test", "--model", "/m", "a.wav"])
                == .selfTest(files: [URL(fileURLWithPath: "a.wav")], model: URL(fileURLWithPath: "/m", isDirectory: true),
                             forcesCPU: false))
        #expect(LaunchMode(arguments: ["--self-test"]) == .usage(LaunchMode.usage))
        #expect(LaunchMode(arguments: ["--self-test", "--model"]) == .usage(LaunchMode.usage))
        #expect(LaunchMode(arguments: ["--self-test", "--fast", "a.wav"]) == .usage(LaunchMode.usage))
    }

    /// `--cpu` forces the encoder onto the CPU, wherever it stands among the options; it is not a file.
    @Test func theSelfTestCanForceTheCPU() {
        let file = URL(fileURLWithPath: "a.wav"), model = URL(fileURLWithPath: "/m", isDirectory: true)
        #expect(LaunchMode(arguments: ["--self-test", "--cpu", "a.wav"])
                == .selfTest(files: [file], model: nil, forcesCPU: true))
        #expect(LaunchMode(arguments: ["--self-test", "--model", "/m", "a.wav", "--cpu"])
                == .selfTest(files: [file], model: model, forcesCPU: true))
        #expect(LaunchMode(arguments: ["--self-test", "--cpu"]) == .usage(LaunchMode.usage), "Still needs a file")
        #expect(LaunchMode(arguments: ["--cpu"]) == .app(showsSetup: true), "The app itself cannot be forced")
    }

    @Test func snapshotsTakeOneDirectory() {
        #expect(LaunchMode(arguments: ["--snapshots", "/tmp/out"]) == .snapshots(URL(fileURLWithPath: "/tmp/out", isDirectory: true)))
        #expect(LaunchMode(arguments: ["--snapshots"]) == .usage(LaunchMode.usage))
    }
}

@Suite struct AppInfoTests {
    @Test func readsTheIdentityAndTheModelFromAnAppBundle() throws {
        let directory = try TemporaryDirectory()
        let app = directory.url.appendingPathComponent("Example.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let model = resources.appendingPathComponent("Model", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.dictation", "CFBundleName": "Example",
                                    "CFBundleDisplayName": "Example Dev", "CFBundleShortVersionString": "1.2.3",
                                    "CFBundleVersion": "45", "NSHumanReadableCopyright": "Copyright Example",
                                    "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try JSONSerialization.data(withJSONObject: ["base_model": "kea-test", "display_name": "Old Name"])
            .write(to: model.appendingPathComponent("bundle.json"))
        try Data("notice".utf8).write(to: model.appendingPathComponent("NOTICE"))

        let bundle = try #require(Bundle(url: app))
        let info = AppInfo(bundle: bundle)
        #expect(info.name == "Example Dev")
        #expect(info.version == "1.2.3")
        #expect(info.build == "45")
        #expect(info.copyright == "Copyright Example")
        #expect(info.bundleIdentifier == "com.example.dictation")
        #expect(info.modelDirectory?.standardizedFileURL.path == model.standardizedFileURL.path)
        #expect(info.modelName == "kea-test")
        #expect(info.modelNotices.map(\.lastPathComponent) == ["NOTICE"])
    }

    @Test func aBuildTreeHasNoIdentityToKeepDataUnder() throws {
        let directory = try TemporaryDirectory()
        let bundle = try #require(Bundle(url: directory.url))
        let info = AppInfo(bundle: bundle)
        #expect(info.bundleIdentifier == nil)
        #expect(info.modelDirectory == nil)
    }
}
