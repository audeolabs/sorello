import CryptoKit
import DictationCore
import Foundation

/// Why a download stopped, in the four ways the user is told (ARCHITECTURE.md, section 5, "What the user sees").
public enum ModelDownloadFailure: Error, Sendable, Equatable {
    /// There is no connection, it dropped, or it was silent for 30 seconds.
    case connection
    /// The server answered, but not with the model: an error, a refused redirect, or a range it got wrong.
    case server
    /// What arrived is not the pinned model: a manifest or file with the wrong SHA-256, a path that leaves the build,
    /// or more bytes than the build has.
    case check
    /// The disk is full, or the store could not be written.
    case disk
}

/// One run of the download (ARCHITECTURE.md, section 5, "The download"): the manifest first, checked against the pin,
/// then every file it lists, each checked against the manifest when it is complete, into the store's own directory
/// for the download, and finally the one rename that makes it the stored model. Every rule is here, in plain code the
/// tests drive through a transport of their own.
struct ModelFetch: Sendable {
    /// How a run ended.
    enum Ending: Equatable, Sendable {
        case installed(URL)
        case failed(ModelDownloadFailure)
        case cancelled
    }

    /// What a run did, as the verification tools report it.
    struct Tally: Equatable, Sendable {
        /// Bytes that came over the network.
        var fetched: Int64 = 0
        /// For each file continued with a range request, the byte it went on from.
        var continuedFrom: [Int64] = []
        /// Files a server sent again from their start, although a range was asked for.
        var startedAgain = 0
        /// The model was complete in the store already, so nothing was fetched.
        var wasAlreadyThere = false
    }

    /// A file still arriving is kept beside where it goes, with this after its name.
    static let partSuffix = ".sorello-part"

    let pin: ModelPin
    let build: ModelPin.Build
    let store: ModelStore
    let transport: any DownloadTransport
    let clock: any SessionClock
    let version: String
    /// The bytes free on the volume holding the URL, when the system says.
    let freeSpace: @Sendable (URL) -> Int64?
    /// Hears the bytes of the build on disk, as they grow.
    let progress: @Sendable (Int64) -> Void

    /// Downloads the build, unless it is in the store already, and installs it. Cancelling the calling task stops it
    /// at once; what has arrived stays for the next run.
    func run() async -> (Ending, Tally) {
        let identity = build.manifestSHA256
        if case .stored(let url) = store.prepareDownload(identity) {
            return (.installed(url), Tally(wasAlreadyThere: true))
        }
        // One process at a time downloads into the directory; another waits here, then usually finds the model.
        guard let lock = await store.takeDownloadLock() else {
            return (Task.isCancelled ? .cancelled : .failed(.disk), Tally())
        }
        defer { lock.close() }
        let directory: URL
        switch store.prepareDownload(identity) {
        case .stored(let url): return (.installed(url), Tally(wasAlreadyThere: true))
        case .unavailable: return (.failed(.disk), Tally())
        case .download(let place): directory = place
        }

        let watch = SilenceWatch(clock: clock, limit: DownloadRules.silence)
        let work = Task { await Run(fetch: self, directory: directory, watch: watch).perform() }
        // Silence gives the run up as a dropped connection, the same way a cancel stops it.
        watch.whenSilent { work.cancel() }
        let watchdog = Task { await watch.watch() }
        var outcome = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        watchdog.cancel()
        transport.close()
        if outcome.0 == .cancelled && watch.wasSilent { outcome.0 = .failed(.connection) }
        return outcome
    }
}

/// Why a step stopped the run.
private enum Stop: Error {
    case failed(ModelDownloadFailure)
    case cancelled
}

/// One run's work, inside the task the watchdog and a cancel can stop. Used by that task only.
private final class Run {
    let fetch: ModelFetch
    let directory: URL
    let watch: SilenceWatch
    /// The build's bytes on disk: finished files and parts of files. Never more than the pin's size.
    var written: Int64 = 0
    var tally = ModelFetch.Tally()

    init(fetch: ModelFetch, directory: URL, watch: SilenceWatch) {
        self.fetch = fetch
        self.directory = directory
        self.watch = watch
    }

    var build: ModelPin.Build { fetch.build }

    func perform() async -> (ModelFetch.Ending, ModelFetch.Tally) {
        do {
            written = onDisk(ModelPin.manifestName)
            let files = try Self.files(in: try await manifest())
            written += files.reduce(0) { $0 + onDisk($1.path) }
            fetch.progress(written)
            if let free = fetch.freeSpace(directory), free < build.bytes - written { throw Stop.failed(.disk) }
            for file in files { try await obtain(file.path, digest: file.digest) }
            guard let installed = fetch.store.installDownload(build.manifestSHA256) else { throw Stop.failed(.disk) }
            return (.installed(installed), tally)
        } catch Stop.failed(let failure) {
            return (.failed(failure), tally)
        } catch {
            return (.cancelled, tally)
        }
    }

    // MARK: - The manifest

    /// `bundle.json`, which must have the pin's SHA-256: kept from an earlier run when it does, fetched otherwise.
    private func manifest() async throws -> Data {
        try await obtain(ModelPin.manifestName, digest: build.manifestSHA256)
        do {
            return try Data(contentsOf: location(ModelPin.manifestName))
        } catch {
            throw Stop.failed(.disk)
        }
    }

    /// The files the manifest lists, in a fixed order. A path that is absolute, leaves the build's directory, or
    /// could be taken for the store's own bookkeeping is refused, and so is a digest that is not a SHA-256.
    static func files(in manifest: Data) throws -> [(path: String, digest: String)] {
        guard let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let files = object["files"] as? [String: String], !files.isEmpty else {
            throw Stop.failed(.check)
        }
        for (path, digest) in files {
            guard ModelPin.isRelativePath(path), ModelPin.isDigest(digest), path != ModelPin.manifestName,
                  !path.hasSuffix(ModelFetch.partSuffix),
                  !path.split(separator: "/").contains(where: { $0.hasPrefix(".sorello") }) else {
                throw Stop.failed(.check)
            }
        }
        return files.sorted { $0.key < $1.key }.map { (path: $0.key, digest: $0.value) }
    }

    // MARK: - One file

    private func location(_ path: String) -> URL {
        directory.appending(path: path, directoryHint: .notDirectory)
    }

    private func partLocation(_ path: String) -> URL {
        URL(fileURLWithPath: location(path).path + ModelFetch.partSuffix)
    }

    /// The bytes of `path` on disk, finished or in part.
    private func onDisk(_ path: String) -> Int64 {
        Self.size(location(path)) ?? Self.size(partLocation(path)) ?? 0
    }

    private static func size(_ url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    /// Makes `path` complete and checked: kept when an earlier run finished it and it still matches, otherwise
    /// fetched, going on from a part when the server honours a range and from the start when it does not.
    private func obtain(_ path: String, digest: String) async throws {
        let files = FileManager.default
        let final = location(path), part = partLocation(path)
        if let size = Self.size(final) {
            if (try? SpeechCore.sha256(fileURL: final)) == digest { return }
            written -= size
            try? files.removeItem(at: final)
        }
        let handle: FileHandle
        var hasher = SHA256()
        var have: Int64 = 0
        do {
            try files.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = Self.size(part), size > 0 {
                have = size
                try Self.hash(part, into: &hasher)
            } else if !files.createFile(atPath: part.path, contents: nil) {
                throw Stop.failed(.disk)
            }
            handle = try FileHandle(forWritingTo: part)
            try handle.seekToEnd()
        } catch let stop as Stop {
            throw stop
        } catch {
            throw Stop.failed(.disk)
        }
        defer { try? handle.close() }

        /// The part is thrown away: what it held no longer counts.
        func discardPart() {
            written -= have
            have = 0
            try? handle.truncate(atOffset: 0)
            hasher = SHA256()
        }

        var url = fetch.pin.address(of: path, in: build)
        var redirects = 0
        var askedAgain = false
        while true {
            try Task.checkCancellation()
            guard DownloadRules.permits(url, source: fetch.pin.source) else { throw Stop.failed(.server) }
            watch.heard()
            let response: DownloadResponse
            do {
                response = try await fetch.transport.send(DownloadRules.request(url, version: fetch.version, from: have))
            } catch {
                throw Task.isCancelled ? Stop.cancelled : Stop.failed(.connection)
            }
            watch.heard()
            if DownloadRules.redirectStatuses.contains(response.status) {
                redirects += 1
                guard redirects <= DownloadRules.redirects,
                      let next = DownloadRules.redirect(response.headers["location"], from: url) else {
                    throw Stop.failed(.server)
                }
                url = next
                continue
            }
            switch (response.status, have > 0) {
            case (200, false):
                break
            case (206, true):
                guard DownloadRules.rangeStart(response.headers["content-range"]) == have else {
                    throw Stop.failed(.server)
                }
                tally.continuedFrom.append(have)
            case (200, true):
                // The server does not honour ranges: the file comes again from its start.
                discardPart()
                tally.startedAgain += 1
            case (416, true) where !askedAgain:
                // The part is not a beginning the server recognises: ask once more for the whole file.
                discardPart()
                askedAgain = true
                continue
            default:
                throw Stop.failed(.server)
            }
            if let length = response.declaredLength, written + length > build.bytes {
                discardPart()
                try? files.removeItem(at: part)
                throw Stop.failed(.check)
            }
            let received = try await receive(response.body, into: handle, hasher: &hasher, part: part, have: &have)
            if let length = response.declaredLength, received < length { throw Stop.failed(.connection) }
            guard SpeechCore.hex(hasher.finalize()) == digest else {
                discardPart()
                try? files.removeItem(at: part)
                throw Stop.failed(.check)
            }
            do {
                try handle.close()
                try files.moveItem(at: part, to: final)
            } catch {
                throw Stop.failed(.disk)
            }
            return
        }
    }

    /// Writes a body to the part as it arrives and returns how many bytes it held. Stops before writing a byte past
    /// the build's size; that part is deleted, because it can only be wrong.
    private func receive(_ body: AsyncThrowingStream<Data, any Error>, into handle: FileHandle, hasher: inout SHA256,
                         part: URL, have: inout Int64) async throws -> Int64 {
        var received: Int64 = 0
        do {
            for try await chunk in body {
                watch.heard()
                let count = Int64(chunk.count)
                guard written + count <= build.bytes else {
                    written -= have
                    have = 0
                    try? FileManager.default.removeItem(at: part)
                    throw Stop.failed(.check)
                }
                do {
                    try handle.write(contentsOf: chunk)
                } catch {
                    throw Stop.failed(.disk)
                }
                hasher.update(data: chunk)
                received += count
                have += count
                written += count
                tally.fetched += count
                fetch.progress(written)
            }
        } catch let stop as Stop {
            throw stop
        } catch {
            throw Task.isCancelled ? Stop.cancelled : Stop.failed(.connection)
        }
        // A body that ends because its reader was cancelled ends early, not complete.
        if Task.isCancelled { throw Stop.cancelled }
        return received
    }

    /// Feeds what a part already holds to `hasher`, a megabyte at a time.
    private static func hash(_ url: URL, into hasher: inout SHA256) throws {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        while let data = try reader.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
    }
}
