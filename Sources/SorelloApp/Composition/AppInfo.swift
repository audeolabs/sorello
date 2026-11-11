import Foundation

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
    /// The model bundle in the app's resources, or nil when the app was built without it.
    var modelDirectory: URL?
    /// The model's name, from its manifest.
    var modelName: String?
    /// `ThirdPartyNotices.md` in the app's resources.
    var thirdPartyNotices: URL?
    /// The display font's licence.
    var fontLicence: URL?

    /// The running app's identity and resources.
    static func main() -> AppInfo { AppInfo(bundle: .main) }

    init(name: String, version: String, build: String, copyright: String? = nil, bundleIdentifier: String? = nil,
         modelDirectory: URL? = nil, modelName: String? = nil, thirdPartyNotices: URL? = nil,
         fontLicence: URL? = nil) {
        self.name = name
        self.version = version
        self.build = build
        self.copyright = copyright
        self.bundleIdentifier = bundleIdentifier
        self.modelDirectory = modelDirectory
        self.modelName = modelName
        self.thirdPartyNotices = thirdPartyNotices
        self.fontLicence = fontLicence
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
        self.init(name: string("CFBundleDisplayName") ?? string("CFBundleName")
                      ?? bundle.executableURL?.lastPathComponent ?? ProcessInfo.processInfo.processName,
                  version: string("CFBundleShortVersionString") ?? "",
                  build: string("CFBundleVersion") ?? "",
                  copyright: string("NSHumanReadableCopyright"),
                  bundleIdentifier: isApp ? bundle.bundleIdentifier : nil,
                  modelDirectory: hasModel ? model : nil,
                  modelName: hasModel ? model.flatMap(Self.modelName(in:)) : nil,
                  thirdPartyNotices: resources?.appendingPathComponent("ThirdPartyNotices.md"),
                  fontLicence: resources?.appendingPathComponent("Fonts/GeistSerif-OFL.txt"))
    }

    /// The model's name in its manifest: the base model it was exported from.
    static func modelName(in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("bundle.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return manifest["base_model"] as? String
    }

    /// This copy with the model at `directory` (the self-test's `--model`).
    func withModel(at directory: URL) -> AppInfo {
        var copy = self
        copy.modelDirectory = directory
        copy.modelName = Self.modelName(in: directory)
        return copy
    }

    /// The model's notices beside the model: its licence, NVIDIA's attribution, and the inference code's licence.
    var modelNotices: [URL] {
        guard let modelDirectory else { return [] }
        return ["NOTICE", "LICENSE", "Software-LICENSE"].map { modelDirectory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
