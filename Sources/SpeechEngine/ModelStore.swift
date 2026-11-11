import Foundation
import Synchronization

/// The model's stable home, one directory per manifest digest (ARCHITECTURE.md, section 5). Core ML's on-device
/// specialization cache is keyed by the encoder weight file's path and identity, so a copy that is never rewritten
/// stays warm across app updates that keep the model. A model comes in two ways, both ending in the same locked,
/// marked rename: copied from an app that carries it, or downloaded into a directory of its own inside the store.
/// Nothing is logged.
final class ModelStore: Sendable {
    /// What a download should do, as the store sees it.
    enum DownloadPlace: Equatable, Sendable {
        /// The model is already complete here.
        case stored(URL)
        /// Download into this directory. It is the store's own, and it is the same directory after a quit.
        case download(URL)
        /// The store cannot be written.
        case unavailable
    }

    let root: URL
    private static let marker = ".sorello-complete"
    private static let stagingPrefix = ".staging-"
    private static let downloadPrefix = ".download-"
    private static let lockName = ".lock"
    /// Set once a copy from the app is rejected; the app's copy is then loaded in place until the next launch.
    private let disabled = Mutex(false)
    /// Test seam: runs between an install's completeness check and its replacement of the target. Nil in production.
    private let afterCheck: (@Sendable () -> Void)?

    /// `root` is `Application Support/<bundle id>/Models` in the app, so app variants never collect each other's
    /// models.
    init(root: URL, afterCheck: (@Sendable () -> Void)? = nil) {
        self.root = root
        self.afterCheck = afterCheck
    }

    // MARK: - The pinned model

    /// `<root>/<identity>` when it holds the complete model `identity`. Once it does, every other entry under root,
    /// an unfinished download included, is removed.
    func stored(_ identity: String) -> URL? {
        let target = directory(identity)
        return exclusively { () -> URL? in
            guard isComplete(target, identity: identity) else { return nil }
            collectGarbage(keeping: identity)
            return target
        } ?? nil
    }

    /// Copies an app's own model into the store as `identity`, unless it is there already, and returns where it is.
    /// Nil when `bundle` is not that model, when the copy fails, or after a copy was rejected in this process.
    func install(bundle: URL, as identity: String) -> URL? {
        guard !disabled.withLock({ $0 }), (try? self.identity(of: bundle)) == identity else { return nil }
        let target = directory(identity)
        return exclusively { () -> URL? in
            if !isComplete(target, identity: identity) {
                let staging = root.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
                excludeFromBackup()
                if isComplete(target, identity: identity) { return target }
                afterCheck?()
                guard (try? FileManager.default.copyItem(at: bundle, to: staging)) != nil,
                      commit(staging, to: target, identity: identity) else {
                    try? FileManager.default.removeItem(at: staging)
                    return nil
                }
            }
            collectGarbage(keeping: identity)
            return target
        } ?? nil
    }

    // MARK: - Downloads

    /// Where a download of `identity` goes: `<root>/.download-<identity>`, made if missing, or the stored model if it
    /// is complete already. The directory is hidden, so nothing that lists models ever takes it for one, and it keeps
    /// what it holds until the model is complete.
    func prepareDownload(_ identity: String) -> DownloadPlace {
        let target = directory(identity), download = downloadDirectory(identity)
        return exclusively { () -> DownloadPlace in
            if isComplete(target, identity: identity) { return .stored(target) }
            excludeFromBackup()
            do {
                try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                return .download(download)
            } catch {
                return .unavailable
            }
        } ?? .unavailable
    }

    /// Makes the finished download of `identity` the stored model: the same locked, marked rename as a copy from the
    /// app. Nil when the download's manifest is not `identity`'s; then it is left as it was. Every file was checked as
    /// it arrived, and the engine checks every one again when it loads.
    func installDownload(_ identity: String) -> URL? {
        let target = directory(identity), download = downloadDirectory(identity)
        return exclusively { () -> URL? in
            if !isComplete(target, identity: identity) {
                guard (try? self.identity(of: download)) == identity, holdsEveryFile(download) else { return nil }
                afterCheck?()
                guard commit(download, to: target, identity: identity) else { return nil }
            }
            collectGarbage(keeping: identity)
            return target
        } ?? nil
    }

    // MARK: - The app's copy, opened in place

    /// Opens an app's own model with `make` and its first load with `prepare`, from the store when possible,
    /// installing it first when missing. If either rejects the store copy, that copy is removed, the store is off for
    /// this process and `bundle` is opened instead; the next launch installs again.
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
            disable()
            discard(directory)
            return try attempt(bundle)
        }
    }

    /// The store's copy of `bundle`, under the digest of the bundle's own manifest, installed if missing; `bundle`
    /// itself on any failure or after a rejection.
    func directory(for bundle: URL) -> URL {
        guard let identity = try? identity(of: bundle) else { return bundle }
        return install(bundle: bundle, as: identity) ?? bundle
    }

    /// Stops copying from the app for this process, after a copy was rejected.
    func disable() {
        disabled.withLock { $0 = true }
    }

    /// Removes a model directory directly inside root; anything else is ignored.
    func discard(_ directory: URL) {
        guard directory.standardizedFileURL.deletingLastPathComponent().path == root.standardizedFileURL.path,
              !directory.lastPathComponent.hasPrefix(".") else { return }
        _ = exclusively { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Steps

    private func directory(_ identity: String) -> URL {
        root.appendingPathComponent(identity, isDirectory: true)
    }

    private func downloadDirectory(_ identity: String) -> URL {
        root.appendingPathComponent(Self.downloadPrefix + identity, isDirectory: true)
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
        SpeechCore.sha256(try Data(contentsOf: bundle.appendingPathComponent(ModelPin.manifestName)))
    }

    /// The marker is written last, before the rename, so a directory without it is an interrupted or foreign copy.
    /// The copy is writable, so its manifest, which the integrity check trusts, must also be the pinned one.
    private func isComplete(_ directory: URL, identity: String) -> Bool {
        (try? Data(contentsOf: directory.appendingPathComponent(Self.marker))) == Data(identity.utf8)
            && (try? self.identity(of: directory)) == identity
    }

    /// Marks `staging` complete and renames it to `target`, replacing an incomplete `target`. The rename keeps every
    /// inode, so the first load at the final path is the only cold one. Called under the lock.
    private func commit(_ staging: URL, to target: URL, identity: String) -> Bool {
        let files = FileManager.default
        do {
            if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
            try Data(identity.utf8).write(to: staging.appendingPathComponent(Self.marker))
            try files.moveItem(at: staging, to: target)
            return true
        } catch {
            // Another process may have won the race outside the lock's reach; use its copy if it is whole.
            return isComplete(target, identity: identity)
        }
    }

    /// Whether every file `directory`'s manifest lists is there. Their bytes were checked as they arrived; this keeps
    /// a download that is missing a file from ever becoming the model.
    private func holdsEveryFile(_ directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(ModelPin.manifestName)),
              let files = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["files"] as? [String: String],
              !files.isEmpty else { return false }
        return files.keys.allSatisfy { path in
            ModelPin.isRelativePath(path)
                && FileManager.default.fileExists(atPath: directory.appending(path: path, directoryHint: .notDirectory).path)
        }
    }

    private func excludeFromBackup() {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = root
        try? excluded.setResourceValues(values)
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
