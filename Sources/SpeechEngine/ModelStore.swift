import Foundation
import Synchronization

/// A stable copy of the bundled model, one directory per manifest digest (ARCHITECTURE.md, section 5). Core ML's
/// on-device specialization cache is keyed by the encoder weight file's path and identity, so a copy that is never
/// rewritten stays warm across app updates that keep the model, where loading from the app bundle would compile it
/// again after every update. Every failure falls back to the bundle. Nothing is logged.
final class ModelStore: Sendable {
    let root: URL
    private static let marker = ".sorello-complete"
    private static let stagingPrefix = ".staging-"
    private static let lockName = ".lock"
    /// Set once a store copy is rejected; the bundle is used until the next launch.
    private let disabled = Mutex(false)
    /// Test seam: runs between an install's completeness check and its replacement of the target. Nil in production.
    private let afterCheck: (@Sendable () -> Void)?

    /// `root` is `Application Support/<bundle id>/Models` in the app, so app variants never collect each other's
    /// models.
    init(root: URL, afterCheck: (@Sendable () -> Void)? = nil) {
        self.root = root
        self.afterCheck = afterCheck
    }

    /// Opens the model with `make` and its first load with `prepare`, from the store when possible, installing it
    /// first when missing. If either rejects the store copy, that copy is removed, the store is off for this process
    /// and `bundle` is opened instead; the next launch installs again.
    func open<T>(bundle: URL, make: (URL) throws -> T, prepare: (T) throws -> Void) throws -> T {
        func attempt(_ directory: URL) throws -> T {
            let model = try make(directory)
            try prepare(model)
            return model
        }
        let directory = self.directory(for: bundle)
        guard directory != bundle else { return try attempt(bundle) }
        do {
            return try attempt(directory)
        } catch {
            disabled.withLock { $0 = true }
            discard(directory)
            return try attempt(bundle)
        }
    }

    /// `<root>/<SHA-256 of bundle.json>`, complete and untouched if present, otherwise installed from `bundle`; other
    /// entries under root, except the lock file, are removed. Returns `bundle` on any failure or after a rejection.
    func directory(for bundle: URL) -> URL {
        guard !disabled.withLock({ $0 }), let identity = try? identity(of: bundle) else { return bundle }
        let target = root.appendingPathComponent(identity, isDirectory: true)
        return exclusively { () -> URL in
            if !isComplete(target, identity: identity) {
                guard install(bundle, at: target, identity: identity) else { return bundle }
            }
            collectGarbage(keeping: identity)
            return target
        } ?? bundle
    }

    /// Removes a model directory directly inside root; anything else is ignored.
    func discard(_ directory: URL) {
        guard directory.standardizedFileURL.deletingLastPathComponent().path == root.standardizedFileURL.path,
              !directory.lastPathComponent.hasPrefix(".") else { return }
        _ = exclusively { try? FileManager.default.removeItem(at: directory) }
    }

    /// Other app processes share root, and a recursive removal is not atomic, so every check, install, removal and
    /// collection runs under an advisory lock on `<root>/.lock`; nil if the lock cannot be taken.
    private func exclusively<T>(_ body: () -> T) -> T? {
        guard (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])) != nil else {
            return nil
        }
        let descriptor = Darwin.open(root.appendingPathComponent(Self.lockName).path,
                                     O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return nil }
        // Closing the descriptor releases the lock.
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { return nil }
        }
        return body()
    }

    private func identity(of bundle: URL) throws -> String {
        SpeechCore.sha256(try Data(contentsOf: bundle.appendingPathComponent("bundle.json")))
    }

    /// The marker is written last, before the rename, so a directory without it is an interrupted or foreign copy.
    /// The copy is writable, so its manifest, which the integrity check trusts, must also be the bundle's own.
    private func isComplete(_ directory: URL, identity: String) -> Bool {
        (try? Data(contentsOf: directory.appendingPathComponent(Self.marker))) == Data(identity.utf8)
            && (try? self.identity(of: directory)) == identity
    }

    /// `copyItem` clones on APFS; the rename keeps every inode, so the first load at the final path is the only cold
    /// one.
    private func install(_ bundle: URL, at target: URL, identity: String) -> Bool {
        let files = FileManager.default
        let staging = root.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = root
            try? excluded.setResourceValues(values)
            if isComplete(target, identity: identity) { return true }
            afterCheck?()
            if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
            try files.copyItem(at: bundle, to: staging)
            try Data(identity.utf8).write(to: staging.appendingPathComponent(Self.marker))
            do {
                try files.moveItem(at: staging, to: target)
            } catch {
                // Another install won the race; use its copy.
                try? files.removeItem(at: staging)
                return isComplete(target, identity: identity)
            }
            return true
        } catch {
            try? files.removeItem(at: staging)
            return false
        }
    }

    /// Removes only root's direct entries; a symbolic link is removed, not followed.
    private func collectGarbage(keeping identity: String) {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name != identity && name != Self.lockName {
            try? files.removeItem(at: root.appendingPathComponent(name))
        }
    }
}
