import AppKit
import DictationCore

/// The app in front, read when a dictation starts (the `FrontmostAppReading` port), for the dictionary's per-app
/// words. Only its bundle identifier and name are read.
public struct FrontmostApp: FrontmostAppReading {
    public init() {}

    @MainActor
    public func frontmostApp() -> AppIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return Self.identity(bundleID: app.bundleIdentifier, name: app.localizedName, pid: app.processIdentifier,
                             ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// Names an app, or nil when it is this process or has no bundle identifier. A missing name falls back to the
    /// bundle identifier.
    static func identity(bundleID: String?, name: String?, pid: pid_t, ownPID: pid_t) -> AppIdentity? {
        guard pid != ownPID, let bundleID, !bundleID.isEmpty else { return nil }
        let name = name.flatMap { $0.isEmpty ? nil : $0 } ?? bundleID
        return AppIdentity(bundleID: bundleID, name: name)
    }
}
