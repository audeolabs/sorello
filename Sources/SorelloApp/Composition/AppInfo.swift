import Foundation
import SpeechEngine

/// Who the app is and where its bundled resources are, read from the bundle (ARCHITECTURE.md, sections 8 and 10).
/// Nothing here is written in code: a copy run from a build tree has no bundle identifier, and then the app does not
/// start (only the self-test and the snapshots, which keep no data, run there).
nonisolated struct AppInfo: Sendable, Equatable {
    /// The app's name as installed: "Sorello" or "Sorello Dev".
    var name: String
    var version: String
    var build: String
    var copyright: String?
    /// Where the app keeps its data, `Application Support/<bundle id>`; nil outside a bundle.
    var bundleIdentifier: String?
    /// The model bundle in the app's resources, or nil when the app was built without it, as it usually is: the app
    /// downloads its model.
    var modelDirectory: URL?
    /// The pin, `model.lock.json` in the app's resources: which model the app uses and where it downloads it from.
    /// Nil outside a bundle, or when the file cannot be read.
    var pin: ModelPin?
    /// The model's name, from the pin.
    var modelName: String?
    /// The model's notices, `ModelNotices` in the app's resources, which ship whether or not the app carries the model.
    var modelNoticesDirectory: URL?
    /// `ThirdPartyNotices.md` in the app's resources.
    var thirdPartyNotices: URL?
    /// The display font's licence, `Fonts/Urbanist-OFL.txt` in the app's resources.
    var fontLicence: URL?
    /// Where the app looks for a newer build of itself, `SUFeedURL` in its `Info.plist`; nil in a build with no update
    /// feed, as every development build is, and then the app has no updater (ARCHITECTURE.md, section 6, "Updates").
    var updateFeed: URL?

    /// The running app's identity and resources.
    static func main() -> AppInfo { AppInfo(bundle: .main) }

    init(name: String, version: String, build: String, copyright: String? = nil, bundleIdentifier: String? = nil,
         modelDirectory: URL? = nil, pin: ModelPin? = nil, modelName: String? = nil,
         modelNoticesDirectory: URL? = nil, thirdPartyNotices: URL? = nil, fontLicence: URL? = nil,
         updateFeed: URL? = nil) {
        self.name = name
        self.version = version
        self.build = build
        self.copyright = copyright
        self.bundleIdentifier = bundleIdentifier
        self.modelDirectory = modelDirectory
        self.pin = pin
        self.modelName = modelName ?? pin?.model
        self.modelNoticesDirectory = modelNoticesDirectory
        self.thirdPartyNotices = thirdPartyNotices
        self.fontLicence = fontLicence
        self.updateFeed = updateFeed
    }

    /// The identity `bundle` declares. Its resources are used only when it is an app bundle, so a build tree never
    /// borrows a developer's files.
    init(bundle: Bundle) {
        func string(_ key: String) -> String? { bundle.object(forInfoDictionaryKey: key) as? String }
        let isApp = bundle.bundleURL.pathExtension == "app"
        let resources = isApp ? bundle.resourceURL : nil
        let model = resources?.appendingPathComponent("Model", isDirectory: true)
        let hasModel = model.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("bundle.json").path) }
            ?? false
        let pin = resources.flatMap { try? ModelPin(contentsOf: $0.appendingPathComponent("model.lock.json")) }
        self.init(name: string("CFBundleDisplayName") ?? string("CFBundleName")
                      ?? bundle.executableURL?.lastPathComponent ?? ProcessInfo.processInfo.processName,
                  version: string("CFBundleShortVersionString") ?? "",
                  build: string("CFBundleVersion") ?? "",
                  copyright: string("NSHumanReadableCopyright"),
                  bundleIdentifier: isApp ? bundle.bundleIdentifier : nil,
                  modelDirectory: hasModel ? model : nil,
                  pin: pin,
                  modelName: pin?.model ?? (hasModel ? model.flatMap(Self.modelName(in:)) : nil),
                  modelNoticesDirectory: resources?.appendingPathComponent("ModelNotices", isDirectory: true),
                  thirdPartyNotices: resources?.appendingPathComponent("ThirdPartyNotices.md"),
                  fontLicence: resources?.appendingPathComponent("Fonts/Urbanist-OFL.txt"),
                  updateFeed: isApp ? string("SUFeedURL").flatMap(URL.init(string:)) : nil)
    }

    /// The model's name in its manifest, the base model it was exported from, for a model given on the command line
    /// to a copy that has no pin.
    static func modelName(in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("bundle.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return manifest["base_model"] as? String
    }

    /// This copy with the model at `directory` (the self-test's `--model`).
    func withModel(at directory: URL) -> AppInfo {
        var copy = self
        copy.modelDirectory = directory
        copy.modelName = pin?.model ?? Self.modelName(in: directory)
        return copy
    }

    /// The model's notices: its licence, NVIDIA's attribution, and the inference code's licence.
    var modelNotices: [URL] {
        guard let modelNoticesDirectory else { return [] }
        return ["NOTICE", "LICENSE", "Software-LICENSE"].map { modelNoticesDirectory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
