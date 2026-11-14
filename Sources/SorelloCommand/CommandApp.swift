import Darwin
import Foundation

/// The app a `sorello` command belongs to (ARCHITECTURE.md, section 10, "The command", "Its app"): the bundle that
/// holds the command's real file at `Contents/Helpers/sorello`, and what its `Info.plist` says about it.
struct CommandApp: Equatable {
    /// The `.app` directory.
    let bundle: URL
    let bundleIdentifier: String
    let name: String
    let version: String
    let build: String

    /// `Contents/Resources`, where the pin and any model the app carries are.
    var resources: URL { bundle.appendingPathComponent("Contents/Resources", isDirectory: true) }

    /// The app around the command started at `executablePath`, followed through every symbolic link; nil for a copy
    /// outside an app, a hard link elsewhere, the build tree's own executable, or an app whose `Info.plist` names no
    /// bundle identifier.
    init?(executablePath: String) {
        guard let resolved = realpath(executablePath, nil) else { return nil }
        defer { free(resolved) }
        let helper = URL(fileURLWithPath: String(cString: resolved))
        let helpers = helper.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard helper.lastPathComponent == "sorello", helpers.lastPathComponent == "Helpers",
              contents.lastPathComponent == "Contents", bundle.pathExtension == "app",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = plist as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
            return nil
        }
        func string(_ key: String) -> String? { (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        self.bundle = bundle
        bundleIdentifier = identifier
        name = string("CFBundleDisplayName") ?? string("CFBundleName") ?? bundle.deletingPathExtension().lastPathComponent
        version = string("CFBundleShortVersionString") ?? "?"
        build = string("CFBundleVersion") ?? "?"
    }
}
