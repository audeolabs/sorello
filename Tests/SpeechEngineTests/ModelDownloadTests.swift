import DictationCore
import Foundation
import Synchronization
import Testing
@testable import SpeechEngine

/// The download (ARCHITECTURE.md, section 5, "The download"), against a server of the tests' own: every rule, and
/// after every failure a store that holds nothing the engine could load. The model is invented: a few files of made-up
/// bytes, a manifest listing them, and a pin for it under example.com.
struct ModelDownloadTests {
    static let source = "https://models.example.com/resolve/0123abcd"
    static let weights = "Encoder.mlmodelc/weights/weight.bin"

    /// An invented build: its files, its manifest, and a pin that lists it.
    struct Build {
        let files: [String: Data]
        let manifest: Data
        let pin: ModelPin
        var identity: String { SpeechCore.sha256(manifest) }
        var size: Int64 { Int64(manifest.count + files.values.reduce(0) { $0 + $1.count }) }

        /// `paths` overrides the paths the manifest lists, for a manifest that names a path it must not.
        init(listing paths: [String: String]? = nil, bytes: Int64? = nil) {
            files = ["frontend.json": Data("{\"bins\":128}".utf8),
                     ModelDownloadTests.weights: Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }),
                     "vocabulary.json": Data("{\"0\":\"▁invented\"}".utf8)]
            let listing = paths ?? files.mapValues { SpeechCore.sha256($0) }
            manifest = (try? JSONSerialization.data(withJSONObject: ["model": "kea-invented", "files": listing],
                                                    options: [.sortedKeys])) ?? Data()
            let size = bytes ?? Int64(manifest.count + files.values.reduce(0) { $0 + $1.count })
            let text = """
                {"model": "kea-invented", "manifest": "bundle.json", "source": "\(ModelDownloadTests.source)",
                 "builds": [{"directory": "macos26", "manifest_sha256": "\(SpeechCore.sha256(manifest))",
                             "bytes": \(size), "requires": {"macos": "26.0"}}]}
                """
            // The pin is invented here and always reads.
            pin = (try? ModelPin(data: Data(text.utf8))) ?? { fatalError("The invented pin does not read") }()
        }

        static func address(_ path: String) -> String { "\(ModelDownloadTests.source)/macos26/\(path)" }

        /// Every file at its address, the manifest included.
        var served: [String: Data] {
            var served = [Self.address("bundle.json"): manifest]
            for (path, data) in files { served[Self.address(path)] = data }
            return served
        }
    }

    /// A store in a temporary directory, a server, a clock, and downloads made over them.
    final class Setup: Sendable {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloadTests-\(UUID().uuidString)", isDirectory: true)
        let build: Build
        let server: FakeServer
        let clock = SteppedClock()
        let freeSpace: Mutex<Int64?> = Mutex(nil)
        var store: URL { base.appendingPathComponent("Models", isDirectory: true) }
        var installed: URL { store.appendingPathComponent(build.identity, isDirectory: true) }

        init(_ build: Build = Build()) {
            self.build = build
            server = FakeServer(files: build.served)
        }

        /// A new download over the same store: what the app makes at each launch.
        func download(on system: String = "27.2", version: String = "9.9") -> ModelDownload {
            let mac = MacDescription(system: SystemVersion(system) ?? SystemVersion(ProcessInfo.processInfo.operatingSystemVersion))
            let model = PinnedModel(pin: build.pin, storeDirectory: store, mac: mac)
            let server = self.server
            return ModelDownload(model: model, version: version, transport: { server }, clock: clock,
                                 freeSpace: { [self] _ in self.freeSpace.withLock { $0 } })
        }

        /// The files of a directory by relative path, ignoring the store's bookkeeping.
        func contents(of directory: URL) -> [String: Data] {
            var result: [String: Data] = [:]
            let prefix = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { return result }
            for case let url as URL in walker {
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue
                else { continue }
                result[String(path.dropFirst(prefix.count))] = try? Data(contentsOf: url)
            }
            return result
        }

        /// What an unfinished download holds, by relative path.
        var downloaded: [String: Data] {
            contents(of: store.appendingPathComponent(".download-\(build.identity)", isDirectory: true))
        }

        /// Every byte the store holds for this build, finished or not.
        var bytesOnDisk: Int64 {
            Int64(downloaded.values.reduce(0) { $0 + $1.count } + contents(of: installed).values.reduce(0) { $0 + $1.count })
        }

        /// After any failure: no model the engine could load, and nothing at the place it would load from.
        func expectNothingLoadable(sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(ModelStore(root: store).stored(build.identity) == nil, sourceLocation: sourceLocation)
            #expect(!FileManager.default.fileExists(atPath: installed.path), sourceLocation: sourceLocation)
        }

        deinit { try? FileManager.default.removeItem(at: base) }
    }

    /// Runs a download to its end within ten seconds of real time.
    func finish(_ download: ModelDownload, sourceLocation: SourceLocation = #_sourceLocation) async -> ModelDownloadReport? {
        await within(10, sourceLocation: sourceLocation) { await download.download() }
    }

    /// Waits, in real time, until `condition` holds; false after five seconds.
    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    // MARK: - What is fetched

    @Test func theManifestComesFirstThenEveryFileAndOneRenameInstallsThem() async throws {
        let setup = Setup()
        let download = setup.download()
        #expect(download.current == .absent)
        #expect(download.size == setup.build.size)
        let report = try #require(await finish(download))
        #expect(report.state == .installed)
        #expect(download.current == .installed)
        #expect(report.fetched == setup.build.size, "Every byte of the build came once")
        #expect(report.continuedFrom.isEmpty && !report.wasAlreadyThere)
        #expect(setup.server.addresses == ["bundle.json", "Encoder.mlmodelc/weights/weight.bin", "frontend.json",
                                           "vocabulary.json"].map(Build.address))
        var expected = setup.build.files
        expected["bundle.json"] = setup.build.manifest
        #expect(setup.contents(of: setup.installed) == expected)
        #expect(ModelStore(root: setup.store).stored(setup.build.identity) != nil)
        #expect(setup.downloaded.isEmpty, "The download's directory became the model")
        #expect(setup.server.closed == 1, "The run let go of its connection")
    }

    /// Each request is a GET with Sorello's name and version and English, and nothing else.
    @Test func everyRequestCarriesOnlyItsNameItsLanguageAndARangeWhenItContinues() async throws {
        let setup = Setup()
        setup.server.answer(Build.address(Self.weights), .cutOff(after: 50_000))
        #expect(await finish(setup.download(version: "0.0.1"))?.state == .failed(.connection))
        #expect(await finish(setup.download(version: "0.0.1"))?.state == .installed)
        let plain = ["User-Agent": "Sorello/0.0.1", "Accept-Language": "en"]
        let continued = setup.server.requests.filter { $0.headers["Range"] != nil }
        #expect(continued.map(\.url.absoluteString) == [Build.address(Self.weights)])
        #expect(continued.first?.headers == plain.merging(["Range": "bytes=50000-"]) { $1 })
        for request in setup.server.requests where request.headers["Range"] == nil {
            #expect(request.headers == plain, "\(request.url)")
        }
        #expect(DownloadRules.request(try #require(URL(string: Build.address("bundle.json"))), version: "1.2",
                                      from: 0).headers == ["User-Agent": "Sorello/1.2", "Accept-Language": "en"])
    }

    @Test func aModelAlreadyHereIsNotFetchedAgain() async throws {
        let setup = Setup()
        #expect(await finish(setup.download())?.state == .installed)
        let asked = setup.server.requests.count
        let again = setup.download()
        #expect(again.current == .installed, "A model in the store is there at launch")
        let report = try #require(await finish(again))
        #expect(report.state == .installed && report.fetched == 0 && report.wasAlreadyThere)
        #expect(setup.server.requests.count == asked)
    }

    @Test func theManifestMustHaveThePinsDigest() async throws {
        let setup = Setup()
        setup.server.put(Build.address("bundle.json"), Data("{\"files\":{}}".utf8))
        let download = setup.download()
        #expect(await finish(download)?.state == .failed(.check))
        #expect(download.current == .failed(.check))
        #expect(setup.server.addresses == [Build.address("bundle.json")], "Nothing listed by a wrong manifest is asked for")
        #expect(setup.downloaded.isEmpty, "A manifest that fails its check is deleted")
        setup.expectNothingLoadable()
    }

    @Test(arguments: ["../outside.bin", "/etc/outside.bin", "Encoder.mlmodelc/../../outside.bin", "a//b.bin",
                      ".sorello-complete", "frontend.json.sorello-part"])
    func aListedPathThatLeavesTheBuildIsRefused(path: String) async throws {
        let setup = Setup(Build(listing: [path: SpeechCore.sha256(Data("x".utf8))]))
        #expect(await finish(setup.download())?.state == .failed(.check))
        #expect(setup.server.addresses == [Build.address("bundle.json")])
        #expect(!FileManager.default.fileExists(atPath: setup.base.appendingPathComponent("outside.bin").path))
        setup.expectNothingLoadable()
    }

    @Test func aFileWithTheWrongBytesIsDeletedAndTheDownloadFails() async throws {
        let setup = Setup()
        var wrong = try #require(setup.build.files["frontend.json"])
        wrong[0] ^= 0xFF
        setup.server.answer(Build.address("frontend.json"), .body(wrong, declared: true))
        #expect(await finish(setup.download())?.state == .failed(.check))
        #expect(setup.downloaded["frontend.json"] == nil && setup.downloaded["frontend.json.sorello-part"] == nil)
        #expect(setup.downloaded[Self.weights] == setup.build.files[Self.weights], "A checked file is kept")
        setup.expectNothingLoadable()
        // The next run fetches only what is missing.
        let report = try #require(await finish(setup.download()))
        #expect(report.state == .installed)
        #expect(report.fetched == Int64(setup.build.files["frontend.json", default: Data()].count
                                        + setup.build.files["vocabulary.json", default: Data()].count))
    }

    /// The pin's size bounds what is written, however the server answers.
    @Test func neverWritesMoreThanTheBuildHas() async throws {
        let setup = Setup()
        let extra = Data(repeating: 0x5A, count: Int(setup.build.size))
        setup.server.answer(Build.address("frontend.json"), .body(extra, declared: false))
        #expect(await finish(setup.download())?.state == .failed(.check))
        #expect(setup.bytesOnDisk <= setup.build.size)
        #expect(setup.downloaded["frontend.json.sorello-part"] == nil)
        setup.expectNothingLoadable()

        // A length declared beyond the build is refused before anything of it is written.
        let declared = Setup()
        declared.server.answer(Build.address("frontend.json"), .body(extra, declared: true))
        #expect(await finish(declared.download())?.state == .failed(.check))
        #expect(declared.downloaded["frontend.json.sorello-part"] == nil)
        #expect(declared.bytesOnDisk <= declared.build.size)
        declared.expectNothingLoadable()
    }

    /// A pin whose size is smaller than what the files are stops at its size.
    @Test func aBuildLargerThanItsPinIsRefused() async throws {
        let small = Build(bytes: 120_000)
        let setup = Setup(small)
        #expect(await finish(setup.download())?.state == .failed(.check))
        #expect(setup.bytesOnDisk <= 120_000)
        setup.expectNothingLoadable()
    }

    // MARK: - The server and the connection

    @Test(arguments: [404, 500, 403, 304, 300, 206])
    func anAnswerThatIsNotTheFileIsTheServers(status: Int) async throws {
        let setup = Setup()
        setup.server.answer(Build.address("vocabulary.json"), .status(status))
        let download = setup.download()
        #expect(await finish(download)?.state == .failed(.server))
        #expect(download.current == .failed(.server))
        setup.expectNothingLoadable()
    }

    @Test func noConnectionIsTheConnections() async throws {
        let setup = Setup()
        setup.server.answer(Build.address("bundle.json"), .noConnection)
        #expect(await finish(setup.download())?.state == .failed(.connection))
        setup.expectNothingLoadable()
    }

    /// Redirects are followed to HTTPS only, five at most, and carry the same headers and nothing else.
    @Test func redirectsAreFollowedFiveTimesAndOnlyToHTTPS() async throws {
        let setup = Setup()
        let weights = Build.address(Self.weights)
        let hops = (1...5).map { "https://cdn\($0).example.net/blob/weight" }
        setup.server.answer(weights, .redirect(hops[0]))
        for (from, to) in zip(hops, hops.dropFirst()) { setup.server.answer(from, .redirect(to, status: 307)) }
        setup.server.put(hops[4], try #require(setup.build.files[Self.weights]))
        #expect(await finish(setup.download())?.state == .installed)
        #expect(setup.server.addresses.filter { $0.contains("cdn") } == hops)
        #expect(setup.server.requests.allSatisfy { $0.headers == ["User-Agent": "Sorello/9.9", "Accept-Language": "en"] })

        let six = Setup()
        let more = (1...6).map { "https://cdn\($0).example.net/blob/weight" }
        six.server.answer(Build.address(Self.weights), .redirect(more[0]))
        for (from, to) in zip(more, more.dropFirst()) { six.server.answer(from, .redirect(to)) }
        six.server.put(more[5], try #require(six.build.files[Self.weights]))
        #expect(await finish(six.download())?.state == .failed(.server))
        #expect(!six.server.addresses.contains(more[5]), "A sixth redirect is not followed")
        six.expectNothingLoadable()
    }

    @Test(arguments: ["http://cdn.example.net/blob/weight", "ftp://cdn.example.net/blob", "", "//"])
    func aRedirectToAnythingButHTTPSIsRefused(location: String) async throws {
        let setup = Setup()
        setup.server.answer(Build.address(Self.weights), .redirect(location))
        #expect(await finish(setup.download())?.state == .failed(.server))
        #expect(setup.server.addresses.last == Build.address(Self.weights), "Nothing is asked of the refused address")
        setup.expectNothingLoadable()
    }

    @Test func aRelativeRedirectIsResolvedAgainstItsAddress() throws {
        let from = try #require(URL(string: "https://models.example.com/resolve/0123/macos26/bundle.json"))
        #expect(DownloadRules.redirect("/blob/abc", from: from)?.absoluteString == "https://models.example.com/blob/abc")
        #expect(DownloadRules.redirect(nil, from: from) == nil)
        #expect(DownloadRules.redirect("http://models.example.com/blob", from: from) == nil)
    }

    /// Plain HTTP is sent only to the source itself, when that is this Mac, as the verification tool arranges.
    @Test func plainHTTPGoesOnlyToALoopbackSource() throws {
        let https = try #require(URL(string: Self.source))
        let local = try #require(URL(string: "http://127.0.0.1:8123/repo"))
        #expect(DownloadRules.permits(try #require(URL(string: "https://cdn.example.net/x")), source: https))
        #expect(!DownloadRules.permits(try #require(URL(string: "http://models.example.com/x")), source: https))
        #expect(DownloadRules.permits(try #require(URL(string: "http://127.0.0.1:8123/repo/macos26/a")), source: local))
        #expect(!DownloadRules.permits(try #require(URL(string: "http://127.0.0.1:9000/a")), source: local))
        #expect(!DownloadRules.permits(try #require(URL(string: "http://example.net/a")), source: local))
    }

    /// A connection silent for 30 seconds is given up as dropped: in the middle of a body and before its head.
    @Test func silenceIsADroppedConnection() async throws {
        let setup = Setup()
        setup.server.answer(Build.address(Self.weights), .stall(after: 40_960))
        let download = setup.download()
        let run = Task { await download.download() }
        #expect(await eventually { setup.downloaded[Self.weights + ".sorello-part"]?.count == 40_960 })
        let start = setup.clock.now
        setup.clock.advance(to: start + 29.5)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(download.current != .failed(.connection), "Not silent long enough yet")
        setup.clock.advance(to: start + 30.5)
        #expect(await within { await run.value }?.state == .failed(.connection))
        #expect(setup.downloaded[Self.weights + ".sorello-part"]?.count == 40_960, "What arrived is kept")
        setup.expectNothingLoadable()

        let head = Setup()
        head.server.answer(Build.address("bundle.json"), .silentHead)
        let quiet = head.download()
        let waiting = Task { await quiet.download() }
        #expect(await eventually { head.server.requests.count == 1 })
        try? await Task.sleep(for: .milliseconds(20))
        head.clock.advance(to: head.clock.now + 31)
        #expect(await within { await waiting.value }?.state == .failed(.connection))
        head.expectNothingLoadable()
    }

    // MARK: - Stopping and going on

    /// A part of a file is continued with a range request when the server honours it.
    @Test func aDroppedConnectionGoesOnFromWhatArrived() async throws {
        let setup = Setup()
        setup.server.answer(Build.address(Self.weights), .cutOff(after: 81_920))
        let download = setup.download()
        #expect(await finish(download)?.state == .failed(.connection))
        #expect(download.current == .failed(.connection))
        #expect(setup.downloaded[Self.weights + ".sorello-part"]?.count == 81_920)
        setup.expectNothingLoadable()
        #expect(setup.server.requests.count == 2, "Nothing starts again by itself")

        let report = try #require(await finish(download))
        #expect(report.state == .installed)
        #expect(report.continuedFrom == [81_920])
        #expect(setup.server.requests.dropFirst(2).first?.headers["Range"] == "bytes=81920-")
        let weights = Int64(setup.build.files[Self.weights, default: Data()].count)
        #expect(report.fetched == setup.build.size - Int64(setup.build.manifest.count) - 81_920,
                "The manifest and what arrived are not fetched again (\(weights) bytes of weights)")
        #expect(setup.contents(of: setup.installed)[Self.weights] == setup.build.files[Self.weights])
    }

    /// A server that answers a range with the whole file is read from the start.
    @Test func aServerThatIgnoresRangesSendsTheFileFromItsStart() async throws {
        let setup = Setup()
        setup.server.answer(Build.address(Self.weights), .cutOff(after: 81_920), .ignoreRange)
        #expect(await finish(setup.download())?.state == .failed(.connection))
        let report = try #require(await finish(setup.download()))
        #expect(report.state == .installed)
        #expect(report.startedAgain == 1 && report.continuedFrom.isEmpty)
        #expect(setup.contents(of: setup.installed)[Self.weights] == setup.build.files[Self.weights])
    }

    /// A range the server cannot satisfy starts the file again, once.
    @Test func anUnsatisfiableRangeStartsTheFileAgain() async throws {
        let setup = Setup()
        let weights = try #require(setup.build.files[Self.weights])
        setup.server.answer(Build.address(Self.weights), .cutOff(after: 81_920), .status(416))
        #expect(await finish(setup.download())?.state == .failed(.connection))
        #expect(await finish(setup.download())?.state == .installed)
        #expect(setup.server.requests.last?.headers["Range"] == nil)
        #expect(setup.contents(of: setup.installed)[Self.weights] == weights)
    }

    @Test func aBodyThatEndsBeforeItsLengthIsADroppedConnection() async throws {
        let setup = Setup()
        setup.server.answer(Build.address(Self.weights), .shortBody)
        #expect(await finish(setup.download())?.state == .failed(.connection))
        #expect(setup.downloaded[Self.weights + ".sorello-part"]?.count == 100_000)
        setup.expectNothingLoadable()
        #expect(await finish(setup.download())?.state == .installed)
    }

    @Test func cancelStopsAtOnceAndTheNextStartGoesOn() async throws {
        let setup = Setup()
        setup.server.answer(Build.address(Self.weights), .stall(after: 61_440))
        let download = setup.download()
        download.start()
        #expect(await eventually { setup.downloaded[Self.weights + ".sorello-part"]?.count == 61_440 })
        guard case .downloading = download.current else {
            Issue.record("A stalled download is still downloading")
            return
        }
        download.cancel()
        #expect(await eventually { download.current == .absent }, "Cancel stops at once")
        setup.expectNothingLoadable()
        let report = try #require(await finish(download))
        #expect(report.state == .installed)
        #expect(report.continuedFrom == [61_440])
    }

    /// Quitting in the middle leaves the download for the next launch, which goes on from it.
    @Test func aDownloadCutOffByQuittingGoesOnAtTheNextLaunch() async throws {
        let setup = Setup()
        setup.server.answer(Build.address(Self.weights), .stall(after: 102_400))
        var first: ModelDownload? = setup.download()
        first?.start()
        #expect(await eventually { setup.downloaded[Self.weights + ".sorello-part"]?.count == 102_400 })
        first?.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        first = nil
        let next = setup.download()
        #expect(next.current == .absent, "A new launch starts nothing by itself")
        let asked = setup.server.requests.count
        try? await Task.sleep(for: .milliseconds(50))
        #expect(setup.server.requests.count == asked)
        let report = try #require(await finish(next))
        #expect(report.state == .installed && report.continuedFrom == [102_400])
    }

    @Test func startingTwiceRunsOnce() async throws {
        let setup = Setup()
        let download = setup.download()
        download.start()
        download.start()
        async let one = download.download()
        async let two = download.download()
        let (first, second) = await (one, two)
        #expect(first == second && first.state == .installed)
        #expect(setup.server.addresses.count == 4, "Each file is asked for once")
    }

    /// Two processes on one store (two downloads here): the second waits for the first, then finds the model.
    @Test func aSecondProcessWaitsAndFindsTheModel() async throws {
        let setup = Setup()
        setup.server.answer(Build.address(Self.weights), .stall(after: 4096))
        let first = setup.download(), second = setup.download()
        first.start()
        #expect(await eventually { setup.downloaded[Self.weights + ".sorello-part"] != nil })
        second.start()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(setup.server.addresses.count == 2, "The second waits instead of downloading beside the first")
        first.cancel()
        let report = try #require(await finish(second))
        #expect(report.state == .installed && report.continuedFrom == [4096])
    }

    // MARK: - The disk

    @Test func aFullDiskStopsBeforeTheFiles() async throws {
        let setup = Setup()
        setup.freeSpace.withLock { $0 = 1000 }
        let download = setup.download()
        #expect(await finish(download)?.state == .failed(.disk))
        #expect(setup.server.addresses == [Build.address("bundle.json")])
        setup.expectNothingLoadable()
    }

    @Test func aStoreThatCannotBeWrittenIsTheDisks() async throws {
        let setup = Setup()
        try FileManager.default.createDirectory(at: setup.base, withIntermediateDirectories: true)
        try Data("in the way".utf8).write(to: setup.store)
        #expect(await finish(setup.download())?.state == .failed(.disk))
        #expect(setup.server.requests.isEmpty)
    }

    @Test func aFileThatCannotBeWrittenIsTheDisks() async throws {
        let setup = Setup()
        setup.server.answer(Build.address(Self.weights), .stall(after: 4096))
        let download = setup.download()
        download.start()
        #expect(await eventually { setup.downloaded[Self.weights + ".sorello-part"] != nil })
        download.cancel()
        #expect(await eventually { download.current == .absent })
        let directory = setup.store.appendingPathComponent(".download-\(setup.build.identity)/Encoder.mlmodelc/weights")
        let part = directory.appendingPathComponent("weight.bin.sorello-part")
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: part.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: part.path) }
        #expect(await finish(download)?.state == .failed(.disk))
        setup.expectNothingLoadable()
    }

    // MARK: - What the user sees

    @Test func noBuildForThisMacOffersNothing() async throws {
        let setup = Setup()
        let download = setup.download(on: "15.7")
        #expect(download.current == .unavailable)
        #expect(download.size == 0)
        download.start()
        #expect(await finish(download)?.state == .unavailable)
        #expect(setup.server.requests.isEmpty)
    }

    /// The bytes received out of the build's size, never more, from what an earlier run left.
    @Test func progressIsTheBytesOnDiskOutOfTheBuildsSize() async throws {
        let setup = Setup()
        setup.server.answer(Build.address(Self.weights), .cutOff(after: 81_920))
        _ = await finish(setup.download())
        let download = setup.download()
        let seen = Mutex<[ModelDownloadState]>([])
        let stream = download.states()
        let watching = Task {
            for await state in stream {
                seen.withLock { $0.append(state) }
                if state == .installed { return }
            }
        }
        _ = await finish(download)
        _ = await within { await watching.value }
        let states = seen.withLock { $0 }
        #expect(states.first == .absent && states.last == .installed)
        let received = states.compactMap { state -> Int64? in
            if case .downloading(let received) = state { received } else { nil }
        }
        #expect(received.first.map { $0 >= Int64(setup.build.manifest.count) + 81_920 } == true,
                "Progress starts from what is already here")
        #expect(received.allSatisfy { $0 <= setup.build.size })
        #expect(received == received.sorted())
    }

    @Test func progressReachesTheScreenAtMostTenTimesASecond() {
        var pace = ProgressPace()
        let everyMillisecond = (0..<1000).map { Double($0) / 1000 }
        let admitted = everyMillisecond.filter { pace.admits(at: $0) }
        #expect((9...10).contains(admitted.count), "\(admitted.count) reports in a second")
        var fresh = ProgressPace()
        #expect([0, 0.05, 0.25, 0.3, 0.5].filter { fresh.admits(at: $0) } == [0, 0.25, 0.5])
    }

    /// The engine may remove a stored copy it finds damaged; the download then says the model is absent again.
    @Test func refreshFindsAModelThatWasRemoved() async throws {
        let setup = Setup()
        let download = setup.download()
        #expect(await finish(download)?.state == .installed)
        try FileManager.default.removeItem(at: setup.installed)
        download.refresh()
        #expect(download.current == .absent)
    }
}

/// A clock that moves only when the test moves it.
final class SteppedClock: SessionClock {
    private struct Sleeper {
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
        let id: UInt64
    }

    private struct State {
        var now: TimeInterval = 0
        var sleepers: [Sleeper] = []
        var cancelled: Set<UInt64> = []
        var next: UInt64 = 0
    }

    private let state = Mutex(State())

    var now: TimeInterval { state.withLock { $0.now } }

    func sleep(for seconds: TimeInterval) async throws {
        let id = state.withLock { state in
            defer { state.next += 1 }
            return state.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return true }
                    state.sleepers.append(Sleeper(deadline: state.now + max(seconds, 0), continuation: continuation, id: id))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time to `time` and wakes everyone whose deadline has come.
    func advance(to time: TimeInterval) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = max(state.now, time)
            let due = state.sleepers.filter { $0.deadline <= state.now }
            state.sleepers.removeAll { $0.deadline <= state.now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
