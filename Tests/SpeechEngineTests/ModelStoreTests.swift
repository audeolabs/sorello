import Foundation
import Synchronization
import Testing
@testable import SpeechEngine

/// The stable model location: one directory per manifest, kept untouched across app updates, so Core ML's on-device
/// specialization (keyed by the weight file's path and identity) stays warm. Invented files only.
struct ModelStoreTests {
    struct Rejected: Error {}

    /// A temporary base holding a synthetic bundle and the store root, removed on deinit.
    final class Scratch {
        static let weights = "Encoder.mlmodelc/weights/weight.bin"
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        var root: URL { base.appendingPathComponent("store", isDirectory: true) }
        var bundleURL: URL { base.appendingPathComponent("App.app/Model", isDirectory: true) }

        /// Invented files, and a manifest that lists them; the manifest's name alone changes the identity.
        static func synthetic(manifest: String) -> [String: Data] {
            let files = ["vocabulary.json": Data("{\"0\":\"▁synthetic\"}".utf8),
                         "Encoder.mlmodelc/model.mil": Data("program".utf8),
                         weights: Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })]
            let listing = files.keys.sorted().map { "\"\($0)\":\"\(SpeechCore.sha256(files[$0] ?? Data()))\"" }
            return files.merging(["bundle.json": Data("{\"model\":\"\(manifest)\",\"files\":{\(listing.joined(separator: ","))}}".utf8)]) { $1 }
        }

        func bundle(manifest: String) throws -> URL {
            for (path, data) in Self.synthetic(manifest: manifest) {
                let url = bundleURL.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            return bundleURL
        }

        /// Writes the synthetic model `manifest` into `directory`, as a finished download leaves it.
        @discardableResult
        func write(manifest: String, into directory: URL, leaving omitted: Set<String> = []) throws -> String {
            let files = Self.synthetic(manifest: manifest)
            for (path, data) in files where !omitted.contains(path) {
                let url = directory.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            return SpeechCore.sha256(files["bundle.json"] ?? Data())
        }

        deinit { try? FileManager.default.removeItem(at: base) }
    }

    private func identity(_ bundle: URL) throws -> String {
        SpeechCore.sha256(try Data(contentsOf: bundle.appendingPathComponent("bundle.json")))
    }

    private func fileNumber(_ url: URL) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// Entries other than the store's lock files, which stay in root by design.
    private func entries(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0 != ".lock" && $0 != ".download.lock" }.sorted()
    }

    /// Regular files by relative path, ignoring the store's hidden bookkeeping.
    private func contents(of directory: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return result }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            result[String(path.dropFirst(base.count))] = try? Data(contentsOf: url)
        }
        return result
    }

    @Test func installCopiesBundle() throws {
        let scratch = Scratch(), bundle = try scratch.bundle(manifest: "first")
        let directory = ModelStore(root: scratch.root).directory(for: bundle)
        #expect(directory.standardizedFileURL.path == scratch.root.appendingPathComponent(try identity(bundle)).standardizedFileURL.path)
        #expect(contents(of: directory) == contents(of: bundle))
        #expect(contents(of: bundle) == Scratch.synthetic(manifest: "first"))
        #expect((try? scratch.root.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true,
                "The store must be excluded from backups")
    }

    /// The core contract: an installed copy is never rewritten, even when the app bundle itself is replaced by an
    /// update with the same model.
    @Test func reuseKeepsWeightFileIdentity() throws {
        let scratch = Scratch(), bundle = try scratch.bundle(manifest: "first")
        let first = ModelStore(root: scratch.root).directory(for: bundle)
        let inode = fileNumber(first.appendingPathComponent(Scratch.weights))
        #expect(ModelStore(root: scratch.root).directory(for: bundle) == first)
        #expect(fileNumber(first.appendingPathComponent(Scratch.weights)) == inode)
        try FileManager.default.removeItem(at: bundle)
        _ = try scratch.bundle(manifest: "first")
        #expect(ModelStore(root: scratch.root).directory(for: bundle) == first)
        #expect(fileNumber(first.appendingPathComponent(Scratch.weights)) == inode)
        #expect(contents(of: first) == contents(of: bundle))
    }

    @Test func newIdentityReplacesOld() throws {
        let scratch = Scratch(), bundle = try scratch.bundle(manifest: "first")
        let old = ModelStore(root: scratch.root).directory(for: bundle)
        try FileManager.default.removeItem(at: bundle)
        _ = try scratch.bundle(manifest: "second")
        let new = ModelStore(root: scratch.root).directory(for: bundle)
        #expect(new.lastPathComponent == (try identity(bundle)))
        #expect(new != old, "A changed bundle.json must get its own directory")
        #expect(contents(of: new) == Scratch.synthetic(manifest: "second"))
        #expect(!FileManager.default.fileExists(atPath: old.path), "The previous model must be removed")
        #expect(entries(scratch.root) == [new.lastPathComponent])
    }

    @Test func staleStagingAndIncompleteCopiesAreReplaced() throws {
        let scratch = Scratch(), bundle = try scratch.bundle(manifest: "first")
        let stale = scratch.root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stale.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: stale.appendingPathComponent("weights/weight.bin"))
        // A directory with the right name but no completion marker (an interrupted copy) is never trusted.
        let target = scratch.root.appendingPathComponent(try identity(bundle), isDirectory: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try Data("truncated".utf8).write(to: target.appendingPathComponent("bundle.json"))
        let directory = ModelStore(root: scratch.root).directory(for: bundle)
        #expect(!FileManager.default.fileExists(atPath: stale.path), "A stale staging directory must be removed")
        #expect(directory.standardizedFileURL.path == target.standardizedFileURL.path)
        #expect(contents(of: directory) == contents(of: bundle))
        #expect(entries(scratch.root) == [directory.lastPathComponent])
    }

    @Test func failureReturnsBundle() throws {
        let scratch = Scratch(), bundle = try scratch.bundle(manifest: "first")
        // The root cannot be created below a regular file.
        let blocker = scratch.base.appendingPathComponent("blocker")
        try Data("file".utf8).write(to: blocker)
        #expect(ModelStore(root: blocker.appendingPathComponent("store")).directory(for: bundle) == bundle)
        #expect(try Data(contentsOf: blocker) == Data("file".utf8))
        // Without bundle.json there is no identity to store under.
        let empty = scratch.base.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(ModelStore(root: scratch.root).directory(for: empty) == empty)
        #expect(entries(scratch.root).isEmpty, "A failed install must leave nothing behind")
    }

    @Test func collectionStaysInsideRoot() throws {
        let scratch = Scratch(), bundle = try scratch.bundle(manifest: "first")
        let sibling = scratch.base.appendingPathComponent("sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: sibling.appendingPathComponent("keep.txt"))
        try FileManager.default.createDirectory(at: scratch.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: scratch.root.appendingPathComponent("link"), withDestinationURL: sibling)
        let directory = ModelStore(root: scratch.root).directory(for: bundle)
        #expect(entries(scratch.root) == [directory.lastPathComponent])
        #expect(try Data(contentsOf: sibling.appendingPathComponent("keep.txt")) == Data("keep".utf8))
        #expect(contents(of: bundle) == Scratch.synthetic(manifest: "first"))
        // Discarding accepts only this store's model directories.
        let store = ModelStore(root: scratch.root)
        store.discard(sibling)
        store.discard(bundle)
        #expect(FileManager.default.fileExists(atPath: sibling.appendingPathComponent("keep.txt").path))
        #expect(contents(of: bundle) == Scratch.synthetic(manifest: "first"))
        store.discard(directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path), "Discard must remove a store directory")
    }

    /// A store copy that fails verification is removed once and the bundle is used instead; the store then stays out
    /// of the way for this process.
    @Test func rejectedStoreFallsBackOnce() throws {
        let scratch = Scratch(), bundle = try scratch.bundle(manifest: "first")
        let store = ModelStore(root: scratch.root)
        let target = scratch.root.appendingPathComponent(try identity(bundle)).standardizedFileURL.path

        var opened: [String] = []
        let accepted = try store.open(bundle: bundle, make: { url -> URL in opened.append(url.standardizedFileURL.path); return url },
                                      prepare: { _ in })
        #expect(opened == [target] && accepted.standardizedFileURL.path == target)

        opened = []
        let fallback = try store.open(bundle: bundle, make: { url -> URL in
            opened.append(url.standardizedFileURL.path)
            guard url == bundle else { throw Rejected() }
            return url
        }, prepare: { _ in })
        #expect(fallback == bundle)
        #expect(opened == [target, bundle.standardizedFileURL.path])
        #expect(!FileManager.default.fileExists(atPath: target), "A rejected store copy must be removed")

        opened = []
        _ = try store.open(bundle: bundle, make: { url -> URL in opened.append(url.standardizedFileURL.path); return url },
                           prepare: { _ in })
        #expect(opened == [bundle.standardizedFileURL.path])
        #expect(store.directory(for: bundle).path == bundle.path)
        #expect(!FileManager.default.fileExists(atPath: target), "The store must not reinstall in the same process")

        // A broken bundle: each location is tried once, then the error surfaces.
        let other = Scratch(), broken = try other.bundle(manifest: "first")
        var attempts = 0
        #expect(throws: Rejected.self) {
            try ModelStore(root: other.root).open(bundle: broken, make: { _ -> Int in attempts += 1; throw Rejected() },
                                                  prepare: { _ in })
        }
        #expect(attempts == 2)
        // The next launch (a new store) installs again.
        #expect(ModelStore(root: scratch.root).directory(for: bundle).standardizedFileURL.path == target)
    }

    /// The copy is writable, so its manifest is trusted only if it is the bundle's own.
    @Test func tamperedCopyReplaced() throws {
        let scratch = Scratch(), bundle = try scratch.bundle(manifest: "first")
        let directory = ModelStore(root: scratch.root).directory(for: bundle)
        let tampered = Data("{\"0\":\"▁tampered\"}".utf8)
        try tampered.write(to: directory.appendingPathComponent("vocabulary.json"))
        try Data("{\"model\":\"first\",\"files\":{\"vocabulary.json\":\"\(SpeechCore.sha256(tampered))\"}}".utf8)
            .write(to: directory.appendingPathComponent("bundle.json"))
        let again = ModelStore(root: scratch.root).directory(for: bundle)
        #expect(again.standardizedFileURL.path == directory.standardizedFileURL.path)
        #expect(contents(of: again) == contents(of: bundle))
        #expect(entries(scratch.root) == [try identity(bundle)])
    }

    /// Construction can succeed while Core ML's first load of the store copy fails: the bundle is used instead.
    @Test func firstLoadFailureFallsBack() throws {
        let scratch = Scratch(), bundle = try scratch.bundle(manifest: "first")
        let store = ModelStore(root: scratch.root)
        let target = scratch.root.appendingPathComponent(try identity(bundle)).standardizedFileURL.path
        let source = bundle.standardizedFileURL.path
        var made: [String] = [], loaded: [String] = []
        let opened = try store.open(bundle: bundle, make: { url -> String in
            made.append(url.standardizedFileURL.path)
            return url.standardizedFileURL.path
        }, prepare: { path in
            loaded.append(path)
            guard path == source else { throw Rejected() }
        })
        #expect(opened == source && made == [target, source] && loaded == [target, source])
        #expect(!FileManager.default.fileExists(atPath: target), "A store copy that cannot be loaded must be removed")
        #expect(store.directory(for: bundle).path == bundle.path)

        let other = Scratch(), broken = try other.bundle(manifest: "first")
        var loads = 0
        #expect(throws: Rejected.self) {
            try ModelStore(root: other.root).open(bundle: broken, make: { $0 }, prepare: { _ in loads += 1; throw Rejected() })
        }
        #expect(loads == 2)
    }

    @Test func concurrentInstalls() throws {
        let scratch = Scratch(), bundle = try scratch.bundle(manifest: "first")
        let target = scratch.root.appendingPathComponent(try identity(bundle)).standardizedFileURL.path
        let root = scratch.root
        let results = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            let path = ModelStore(root: root).directory(for: bundle).standardizedFileURL.path
            results.withLock { $0.append(path) }
        }
        #expect(results.withLock { $0 }.allSatisfy { $0 == target || $0 == bundle.standardizedFileURL.path },
                "Every racing install must use the store copy or the bundle")
        let settled = ModelStore(root: scratch.root).directory(for: bundle)
        #expect(settled.standardizedFileURL.path == target)
        #expect(contents(of: settled) == contents(of: bundle))
        #expect(entries(scratch.root) == [try identity(bundle)])
    }

    /// Two app processes share the root (two stores here). One install finding no complete copy must not remove the
    /// copy the other finished and handed out meanwhile.
    @Test func installKeepsOtherProcessCopy() throws {
        let scratch = Scratch(), bundle = try scratch.bundle(manifest: "first")
        let target = scratch.root.appendingPathComponent(try identity(bundle)).standardizedFileURL.path
        let other = ModelStore(root: scratch.root)
        let handedOut = Mutex<[String]>([])
        let finished = DispatchGroup()
        let store = ModelStore(root: scratch.root, afterCheck: {
            // The other process installs inside this window if it can. A store that keeps it out makes it wait, so
            // its chance here is bounded.
            finished.enter()
            DispatchQueue.global().async {
                let directory = other.directory(for: bundle)
                let number = ((try? FileManager.default.attributesOfItem(
                    atPath: directory.appendingPathComponent(Scratch.weights).path))?[.systemFileNumber] as? NSNumber)?.uint64Value
                handedOut.withLock { $0 += [directory.standardizedFileURL.path, "\(number ?? 0)"] }
                finished.leave()
            }
            _ = finished.wait(timeout: .now() + 1)
        })
        #expect(store.directory(for: bundle).standardizedFileURL.path == target)
        finished.wait()
        let weights = scratch.root.appendingPathComponent(try identity(bundle)).appendingPathComponent(Scratch.weights)
        #expect(handedOut.withLock { $0 } == [target, "\(fileNumber(weights) ?? 0)"])
        let expected = contents(of: bundle)
        let settled = try ModelStore(root: scratch.root).open(bundle: bundle, make: { url -> URL in
            guard contents(of: url) == expected else { throw Rejected() }
            return url
        }, prepare: { _ in })
        #expect(settled.standardizedFileURL.path == target)
        #expect(entries(scratch.root) == [try identity(bundle)])
    }

    // MARK: - Downloads

    /// A download's own directory in the store, made by the store, under its lock.
    private func downloadDirectory(_ store: ModelStore, _ identity: String,
                                   sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        guard case .download(let directory) = store.prepareDownload(identity) else {
            Issue.record("The store gave no download directory", sourceLocation: sourceLocation)
            throw Rejected()
        }
        return directory
    }

    /// A finished download becomes the stored model in one rename: every inode is kept, so the first load at the
    /// final path is the only cold one.
    @Test func aFinishedDownloadIsInstalledByOneRename() throws {
        let scratch = Scratch(), store = ModelStore(root: scratch.root)
        let identity = SpeechCore.sha256(Scratch.synthetic(manifest: "first")["bundle.json"] ?? Data())
        #expect(store.stored(identity) == nil)
        let download = try downloadDirectory(store, identity)
        #expect(download.standardizedFileURL.deletingLastPathComponent().path == scratch.root.standardizedFileURL.path,
                "A download is kept inside the store")
        #expect(download.lastPathComponent.hasPrefix("."), "A download is hidden from everything that lists models")
        try scratch.write(manifest: "first", into: download)
        let inode = fileNumber(download.appendingPathComponent(Scratch.weights))
        let installed = try #require(store.installDownload(identity))
        #expect(installed.standardizedFileURL.path == scratch.root.appendingPathComponent(identity).standardizedFileURL.path)
        #expect(contents(of: installed) == Scratch.synthetic(manifest: "first"))
        #expect(fileNumber(installed.appendingPathComponent(Scratch.weights)) == inode)
        #expect(entries(scratch.root) == [identity], "The download's directory became the model")
        #expect(ModelStore(root: scratch.root).stored(identity)?.standardizedFileURL.path == installed.standardizedFileURL.path)
    }

    /// An unfinished download is found again after a quit, and left alone until the pinned model is complete.
    @Test func anUnfinishedDownloadOutlivesTheApp() throws {
        let scratch = Scratch()
        let identity = SpeechCore.sha256(Scratch.synthetic(manifest: "first")["bundle.json"] ?? Data())
        let first = try downloadDirectory(ModelStore(root: scratch.root), identity)
        try scratch.write(manifest: "first", into: first, leaving: [Scratch.weights])
        let partial = contents(of: first)
        let later = ModelStore(root: scratch.root)
        #expect(later.stored(identity) == nil)
        #expect(later.installDownload(identity) == nil, "A download missing a file is not a model")
        #expect(try downloadDirectory(later, identity) == first, "The same directory is found again")
        #expect(contents(of: first) == partial, "Looking for the model leaves the download alone")
        #expect(!FileManager.default.fileExists(atPath: scratch.root.appendingPathComponent(identity).path))
    }

    /// Nothing that is not the pinned build is installed: a download without its manifest, or with another one.
    @Test func aDownloadThatIsNotThePinnedBuildIsNotInstalled() throws {
        let scratch = Scratch(), store = ModelStore(root: scratch.root)
        let identity = SpeechCore.sha256(Scratch.synthetic(manifest: "first")["bundle.json"] ?? Data())
        let download = try downloadDirectory(store, identity)
        try scratch.write(manifest: "first", into: download, leaving: ["bundle.json"])
        #expect(store.installDownload(identity) == nil)
        try scratch.write(manifest: "second", into: download)
        #expect(store.installDownload(identity) == nil)
        #expect(store.stored(identity) == nil)
        #expect(entries(scratch.root) == [download.lastPathComponent], "A refused download is left as it was")
    }

    /// Once the pinned model is complete, a download, a stale staging copy and an older model all go.
    @Test func everythingElseGoesOnceThePinnedModelIsComplete() throws {
        let scratch = Scratch(), store = ModelStore(root: scratch.root)
        let old = try scratch.write(manifest: "old", into: scratch.base.appendingPathComponent("old-bundle"))
        _ = store.install(bundle: scratch.base.appendingPathComponent("old-bundle"), as: old)
        let identity = SpeechCore.sha256(Scratch.synthetic(manifest: "first")["bundle.json"] ?? Data())
        let download = try downloadDirectory(store, identity)
        try scratch.write(manifest: "first", into: download, leaving: [Scratch.weights])
        let staging = scratch.root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        #expect(Set(entries(scratch.root)) == [old, download.lastPathComponent, staging.lastPathComponent],
                "Nothing is removed while the pinned model is incomplete")
        // The model arrives another way: copied from an app that carries it.
        let bundle = try scratch.bundle(manifest: "first")
        #expect(store.install(bundle: bundle, as: identity) != nil)
        #expect(entries(scratch.root) == [identity])
        guard case .stored(let stored) = store.prepareDownload(identity) else {
            Issue.record("A download is not begun for a model that is there")
            return
        }
        #expect(stored.standardizedFileURL.path == scratch.root.appendingPathComponent(identity).standardizedFileURL.path)
    }

    /// The copy is writable, so a stored model is trusted only if its marker and manifest are both the pinned ones.
    @Test func aTamperedStoredModelIsNotStored() throws {
        let scratch = Scratch(), store = ModelStore(root: scratch.root)
        let identity = try scratch.write(manifest: "first", into: try downloadDirectory(
            store, SpeechCore.sha256(Scratch.synthetic(manifest: "first")["bundle.json"] ?? Data())))
        let installed = try #require(store.installDownload(identity))
        try Data("{\"model\":\"edited\"}".utf8).write(to: installed.appendingPathComponent("bundle.json"))
        #expect(store.stored(identity) == nil)
    }

    /// A copy from the app is checked against the pinned identity too.
    @Test func aBundleThatIsNotThePinnedBuildIsNotInstalled() throws {
        let scratch = Scratch(), bundle = try scratch.bundle(manifest: "second")
        let identity = SpeechCore.sha256(Scratch.synthetic(manifest: "first")["bundle.json"] ?? Data())
        #expect(ModelStore(root: scratch.root).install(bundle: bundle, as: identity) == nil)
        #expect(entries(scratch.root).isEmpty)
    }

    /// Two processes finishing the same download (two stores here): both are handed the one complete copy.
    @Test func concurrentDownloadInstalls() throws {
        let scratch = Scratch()
        let identity = SpeechCore.sha256(Scratch.synthetic(manifest: "first")["bundle.json"] ?? Data())
        try scratch.write(manifest: "first", into: try downloadDirectory(ModelStore(root: scratch.root), identity))
        let target = scratch.root.appendingPathComponent(identity).standardizedFileURL.path
        let root = scratch.root
        let results = Mutex<[String?]>([])
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            let path = ModelStore(root: root).installDownload(identity)?.standardizedFileURL.path
            results.withLock { $0.append(path) }
        }
        #expect(results.withLock { $0 } == Array(repeating: target, count: 4))
        #expect(contents(of: scratch.root.appendingPathComponent(identity)) == Scratch.synthetic(manifest: "first"))
        #expect(entries(scratch.root) == [identity])
    }

    /// Another process copying the model from its app while a download is being installed must wait for the lock,
    /// and then finds the installed model complete instead of replacing it.
    @Test func aDownloadInstallKeepsOutAnotherProcess() throws {
        let scratch = Scratch(), bundle = try scratch.bundle(manifest: "first")
        let identity = try identity(bundle)
        try scratch.write(manifest: "first", into: try downloadDirectory(ModelStore(root: scratch.root), identity))
        let other = ModelStore(root: scratch.root)
        let handedOut = Mutex<String?>(nil)
        let finished = DispatchGroup()
        let store = ModelStore(root: scratch.root, afterCheck: {
            finished.enter()
            DispatchQueue.global().async {
                handedOut.withLock { $0 = other.install(bundle: bundle, as: identity)?.standardizedFileURL.path }
                finished.leave()
            }
            _ = finished.wait(timeout: .now() + 1)
        })
        let target = scratch.root.appendingPathComponent(identity)
        let inode = fileNumber(try downloadDirectory(ModelStore(root: scratch.root), identity)
            .appendingPathComponent(Scratch.weights))
        #expect(store.installDownload(identity)?.standardizedFileURL.path == target.standardizedFileURL.path)
        finished.wait()
        #expect(handedOut.withLock { $0 } == target.standardizedFileURL.path)
        #expect(fileNumber(target.appendingPathComponent(Scratch.weights)) == inode,
                "The other process used the installed download instead of copying over it")
        #expect(entries(scratch.root) == [identity])
    }
}
