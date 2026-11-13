import DictationCore
import DictionaryKit
import Foundation
import Synchronization
import Testing
@testable import SpeechEngine

/// The engine through the speech port (ARCHITECTURE.md, section 4, "Speech"; Ports.swift), with a fake model, so
/// streams, preparation and retention are tested without Core ML. Audio is an invented tone.
struct EngineTests {
    /// A loud tone of `seconds`, which the silence compactor passes unchanged.
    static func speech(_ seconds: Double) -> [Float] { Signals.tone(seconds, level: -20) }

    /// What the fake model hears for a tone of whole seconds, joined across chunk seams.
    static func words(seconds: Int) -> String {
        guard seconds > 0 else { return "" }
        return (0..<seconds).map { $0 == 0 ? "W0" : "w\($0)" }.joined(separator: " ") + "."
    }

    func engine(_ log: ModelLog, snapshot: DictionarySnapshot = .empty, loader: ModelLoader? = nil,
                lifetime: TimeInterval = 90) -> SpeechEngine {
        SpeechEngine(loader: loader ?? fakeLoader(log), dictionary: { _ in snapshot }, retainedLifetime: lifetime)
    }

    func elapsed(since start: ContinuousClock.Instant) -> Duration { ContinuousClock.now - start }

    // MARK: - Readiness

    @Test func readinessStartsWithTheCurrentValue() async {
        let log = ModelLog()
        let engine = engine(log)
        let first = ReadinessLog(engine)
        #expect(await first.first(1) == [.preparing])
        await prepare(engine)
        #expect(await first.first(2) == [.preparing, .ready])
        let second = ReadinessLog(engine)
        #expect(await second.first(1) == [.ready], "A later subscription starts with the current value")
        await prepare(engine)
        #expect(log.loads == 1, "A ready engine does not load again")
        #expect(first.all == [.preparing, .ready], "Nothing is reported twice")
    }

    /// Calls made while the model is loading share that attempt, although the load keeps the engine's executor busy.
    @Test func concurrentPreparesShareOneAttempt() async {
        let log = ModelLog()
        let release = DispatchSemaphore(value: 0)
        let engine = engine(log, loader: fakeLoader(log, failures: 1, wait: release))
        let readiness = ReadinessLog(engine)
        let calls = (0..<3).map { _ in Task { await engine.prepare() } }
        // The loader is held until the signal, so every call made before it joins the one attempt.
        let fourth = Task { await engine.prepare() }
        let joined = ContinuousClock.now + .seconds(10)
        while engine.preparation.waiting < 4 && ContinuousClock.now < joined { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(engine.preparation.waiting == 4, "Four calls wait for the attempt the first one started")
        release.signal()
        for call in calls + [fourth] { _ = await within { await call.value } }
        #expect(log.loads == 1, "Concurrent calls share one attempt")
        #expect(await readiness.first(2) == [.preparing, .failed(.loadFailed)])
        // A later call after a failure starts a new attempt.
        release.signal()
        await prepare(engine)
        #expect(log.loads == 2)
        #expect(await readiness.first(4) == [.preparing, .failed(.loadFailed), .preparing, .ready])
    }

    @Test func withoutTheModelEverythingFailsAtOnce() async {
        let engine = SpeechEngine(modelDirectory: nil, storeDirectory: nil, dictionary: { _ in .empty })
        #expect(await ReadinessLog(engine).first(1) == [.failed(.modelMissing)])
        await prepare(engine)
        let stream = engine.openStream(SpeechStreamOptions())
        stream.append(Self.speech(1))
        #expect(await finish(stream) == .failure(.engineUnavailable(.modelMissing)))
        #expect(await transcribe(engine, Self.speech(1)) == .failure(.engineUnavailable(.modelMissing)))
    }

    /// Without its model the engine has failed and never says it is preparing; each time it is asked to prepare it
    /// looks again, and once the model has arrived it becomes ready without being made again.
    @Test func withoutTheModelItLooksAgainEachTimeItIsAsked() async throws {
        let log = ModelLog()
        let arrived = Mutex(false)
        let loader = fakeLoader(log)
        let looks = Mutex(0)
        let engine = SpeechEngine(locate: {
            looks.withLock { $0 += 1 }
            return arrived.withLock { $0 } ? loader : nil
        }, present: false, dictionary: { _ in .empty })
        let readiness = ReadinessLog(engine)
        #expect(await readiness.first(1) == [.failed(.modelMissing)])
        await prepare(engine)
        await prepare(engine)
        #expect(looks.withLock { $0 } == 2, "Each preparation looks again")
        let stream = engine.openStream(SpeechStreamOptions())
        stream.append(Self.speech(1))
        #expect(await finish(stream) == .failure(.engineUnavailable(.modelMissing)))
        #expect(readiness.all == [.failed(.modelMissing)], "An engine without its model never says it is preparing")

        arrived.withLock { $0 = true }
        await prepare(engine)
        #expect(await readiness.first(3) == [.failed(.modelMissing), .preparing, .ready])
        #expect(try #require(await transcribe(engine, Self.speech(2))).get() == Self.words(seconds: 2))
        #expect(log.loads == 1)
    }

    /// The app's engine over a pinned model: absent until the store holds it, and a stored copy whose files do not
    /// match its manifest is removed, so the model is absent again and can be downloaded again.
    @Test func aPinnedModelIsMissingUntilItIsStoredAndADamagedCopyGoes() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("EngineTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        let build = ModelDownloadTests.Build()
        let model = PinnedModel(pin: build.pin, storeDirectory: store,
                                mac: MacDescription(system: try #require(SystemVersion("27.2"))))
        let engine = SpeechEngine(model: model, compute: .cpu, dictionary: { _ in .empty })
        let readiness = ReadinessLog(engine)
        #expect(await readiness.first(1) == [.failed(.modelMissing)])
        await prepare(engine)
        #expect(readiness.all == [.failed(.modelMissing)])

        // The invented build has the pinned manifest but not the files the engine needs: it cannot be loaded.
        let models = ModelStore(root: store)
        guard case .download(let directory) = models.prepareDownload(build.identity) else {
            Issue.record("No download directory")
            return
        }
        try build.manifest.write(to: directory.appendingPathComponent("bundle.json"))
        for (path, data) in build.files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        #expect(models.installDownload(build.identity) != nil)
        #expect(model.isOnThisMac)
        await prepare(engine)
        #expect(await readiness.first(3) == [.failed(.modelMissing), .preparing, .failed(.modelMissing)])
        #expect(models.stored(build.identity) == nil, "The damaged copy was removed")
        #expect(!model.isOnThisMac)
    }

    @Test func aBundleWithoutFilesIsMissingAndCorruptFilesAreCorrupt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = SpeechEngine(modelDirectory: directory, storeDirectory: nil, dictionary: { _ in .empty })
        await prepare(empty)
        #expect(await ReadinessLog(empty).first(1) == [.failed(.modelMissing)])

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = CoreMLSpeechModel.requiredFiles + ["Encoder.mlmodelc/model.mil"]
        let files = names.map { "\"\($0)\":\"\(String(repeating: "0", count: 64))\"" }
        try Data("{\"files\":{\(files.joined(separator: ","))}}".utf8).write(to: directory.appendingPathComponent("bundle.json"))
        for name in names {
            let url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("invented".utf8).write(to: url)
        }
        let corrupt = SpeechEngine(modelDirectory: directory, storeDirectory: nil, dictionary: { _ in .empty })
        await prepare(corrupt)
        #expect(await ReadinessLog(corrupt).first(1) == [.failed(.modelCorrupt)], "A file that does not match its hash")
    }

    // MARK: - Streams

    /// However the recording is split into appends, the result equals one append of all of it, and equals a
    /// whole-buffer transcription.
    @Test func anySplitGivesTheSameText() async throws {
        let log = ModelLog()
        let engine = engine(log)
        for seconds in [0.0, 0.5, 3, 14, 15, 16, 29, 31, 44] {
            let recording = Self.speech(seconds)
            let expected = try #require(await transcribe(engine, recording)).get()
            #expect(expected == Self.words(seconds: Int(seconds.rounded(.up))), "\(seconds) s")
            for pieces in [[recording.count], [1, 159, 160, 4096], [16_000], [240_001, 7]] {
                let stream = engine.openStream(SpeechStreamOptions())
                var start = 0, index = 0
                while start < recording.count {
                    let end = min(start + pieces[index % pieces.count], recording.count)
                    stream.append(Array(recording[start..<end]))
                    stream.append([])
                    start = end
                    index += 1
                }
                #expect(try #require(await finish(stream)).get().text == expected, "\(seconds) s in pieces of \(pieces)")
            }
        }
    }

    /// Complete chunks are transcribed while the user is still speaking, so finishing waits only for the last one.
    @Test func chunksAreTranscribedWhileRecording() async throws {
        let log = ModelLog()
        let engine = engine(log)
        await prepare(engine)
        let stream = engine.openStream(SpeechStreamOptions())
        let recording = Self.speech(30)
        for start in stride(from: 0, to: recording.count, by: 1600) {
            stream.append(Array(recording[start..<min(start + 1600, recording.count)]))
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while log.projected.count < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.projected == [240_000, 240_000], "Both complete chunks before finish")
        #expect(try #require(await finish(stream)).get().text == Self.words(seconds: 30))
        #expect(log.projected == [240_000, 240_000, 480_000 - 2 * 208_000], "Only the tail after finish")
    }

    @Test func finishWaitsForPreparation() async throws {
        let log = ModelLog()
        let release = DispatchSemaphore(value: 0)
        let engine = engine(log, loader: fakeLoader(log, wait: release))
        let stream = engine.openStream(SpeechStreamOptions())
        stream.append(Self.speech(3))
        let preparing = Task { await engine.prepare() }
        let result = Task { await finish(stream) }
        try await Task.sleep(for: .milliseconds(100))
        release.signal()
        #expect(await within { await result.value } == .success(SpeechResult(text: Self.words(seconds: 3))))
        _ = await within { await preparing.value }
    }

    @Test func aFailedPreparationFailsEveryWaitingFinish() async {
        let log = ModelLog()
        let release = DispatchSemaphore(value: 0)
        let engine = engine(log, loader: fakeLoader(log, failures: 1, failure: .modelCorrupt, wait: release))
        let first = engine.openStream(SpeechStreamOptions()), second = engine.openStream(SpeechStreamOptions())
        first.append(Self.speech(1))
        second.append(Self.speech(2))
        // The streams start the attempt themselves; a separate prepare could start a second one after this fails.
        let a = Task { await finish(first) }, b = Task { await finish(second) }
        release.signal()
        #expect(await within { await a.value } == .failure(.engineUnavailable(.modelCorrupt)))
        #expect(await within { await b.value } == .failure(.engineUnavailable(.modelCorrupt)))
        // A stream opened after the failure fails at once; preparing again recovers.
        let later = engine.openStream(SpeechStreamOptions())
        later.append(Self.speech(1))
        #expect(await finish(later) == .failure(.engineUnavailable(.modelCorrupt)))
        release.signal()
        await prepare(engine)
        let recovered = engine.openStream(SpeechStreamOptions())
        recovered.append(Self.speech(1))
        #expect(await finish(recovered) == .success(SpeechResult(text: "W0.")))
    }

    /// Cancel wins: a pending finish throws promptly even while the model is busy with something else for a long time.
    @Test func cancelWinsPromptly() async throws {
        let log = ModelLog()
        let release = DispatchSemaphore(value: 0)
        let engine = engine(log, loader: fakeLoader(log, wait: release))
        let preparing = Task { await engine.prepare() }
        let stream = engine.openStream(SpeechStreamOptions())
        stream.append(Self.speech(2))
        let pending = Task { await finish(stream) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        stream.cancel()
        #expect(await within { await pending.value } == .failure(.cancelled))
        #expect(elapsed(since: start) < .milliseconds(500), "The cancel did not wait for the model")
        stream.cancel()
        stream.append(Self.speech(1))
        #expect(await finish(stream) == .failure(.cancelled), "Finish is called once")
        release.signal()
        _ = await within { await preparing.value }
        #expect(log.projected.isEmpty, "A cancelled stream's audio is never transcribed")
    }

    @Test func cancellingTheWaitingTaskCancelsTheStream() async throws {
        let log = ModelLog()
        let release = DispatchSemaphore(value: 0)
        let engine = engine(log, loader: fakeLoader(log, wait: release))
        let preparing = Task { await engine.prepare() }
        let stream = engine.openStream(SpeechStreamOptions())
        stream.append(Self.speech(2))
        let waiting = Task { await finish(stream) }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        #expect(await within { await waiting.value } == .failure(.cancelled))
        release.signal()
        _ = await within { await preparing.value }
        stream.append(Self.speech(1))
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.projected.isEmpty)
    }

    /// The end of a stream's model work, which the iPhone app waits for before it lets the engine go or makes another:
    /// a cancel returns at once, but the chunk the model is working on runs to its end, and waiting for the model's
    /// work returns only after that. Nothing of the stream is transcribed afterwards.
    @Test func waitingForTheModelsWorkOutlastsTheChunkInProgress() async throws {
        let log = ModelLog()
        let model = HeldModel(log: log)
        let engine = SpeechEngine(loader: { model }, dictionary: { _ in .empty })
        await prepare(engine)
        let stream = engine.openStream(SpeechStreamOptions())
        stream.append(Self.speech(31))
        #expect(await within { await model.entered() } != nil, "The first chunk reached the model")
        stream.cancel()
        let ended = Mutex(false)
        let waiting = Task {
            await engine.waitUntilModelWorkEnds()
            ended.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!ended.withLock { $0 }, "The chunk in progress still holds the model")
        model.release()
        _ = await within { await waiting.value }
        #expect(ended.withLock { $0 })
        #expect(model.projections == 1, "The chunk in progress ended before the wait did")
        stream.append(Self.speech(16))
        await engine.waitUntilModelWorkEnds()
        try await Task.sleep(for: .milliseconds(50))
        await engine.waitUntilModelWorkEnds()
        #expect(model.projections == 1, "Nothing of a cancelled stream is transcribed afterwards")
    }

    /// A finished stream's work has ended when its finish returns, and an engine let go once its streams have ended is
    /// freed with its model: the iPhone app releases the model on a memory warning by letting the engine go.
    @Test func anEngineLetGoAfterItsStreamsEndIsFreedWithItsModel() async throws {
        let log = ModelLog()
        weak var freedEngine: SpeechEngine?
        weak var freedModel: HeldModel?
        do {
            let model = HeldModel(log: log, holds: false)
            freedModel = model
            let engine = SpeechEngine(loader: { model }, dictionary: { _ in .empty })
            freedEngine = engine
            await prepare(engine)
            let finished = engine.openStream(SpeechStreamOptions())
            finished.append(Self.speech(2))
            #expect(await finish(finished) == .success(SpeechResult(text: Self.words(seconds: 2))))
            let cancelled = engine.openStream(SpeechStreamOptions())
            cancelled.append(Self.speech(16))
            cancelled.cancel()
            await engine.waitUntilModelWorkEnds()
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while (freedEngine != nil || freedModel != nil) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(freedEngine == nil, "Nothing else keeps the engine")
        #expect(freedModel == nil, "The model goes with the engine")
    }

    @Test func aSecondFinishAndLateAppendsAreIgnored() async throws {
        let log = ModelLog()
        let engine = engine(log)
        let stream = engine.openStream(SpeechStreamOptions())
        stream.append(Self.speech(2))
        #expect(try #require(await finish(stream)).get().text == Self.words(seconds: 2))
        stream.append(Self.speech(5))
        #expect(await finish(stream) == .failure(.cancelled), "Finish is called once")
        stream.cancel()

        let empty = engine.openStream(SpeechStreamOptions())
        #expect(await finish(empty) == .success(SpeechResult(text: "")), "Nothing said is empty text")
        let silent = engine.openStream(SpeechStreamOptions())
        silent.append(Signals.zeros(3))
        #expect(await finish(silent) == .success(SpeechResult(text: "")), "Silence is empty text")
    }

    @Test func invalidAudioFailsTheStream() async {
        let log = ModelLog()
        let engine = engine(log)
        let stream = engine.openStream(SpeechStreamOptions())
        var recording = Self.speech(20)
        recording[100] = .nan
        stream.append(recording)
        #expect(await finish(stream) == .failure(.failed))
    }

    /// The dictionary is read when the stream opens, for the dictation's app, and its casing is applied.
    @Test func dictionarySnapshotIsTakenAtOpen() async throws {
        let log = ModelLog()
        let apps = Mutex<[String?]>([])
        let words = Mutex([DictionaryEntry(text: "W1", strength: 1)])
        let engine = SpeechEngine(loader: fakeLoader(log), dictionary: { app in
            apps.withLock { $0.append(app) }
            return DictionarySnapshot(revision: 1, entries: words.withLock { $0 }, appID: app)
        })
        let stream = engine.openStream(SpeechStreamOptions(appBundleID: "com.example.chat"))
        words.withLock { $0 = [] }
        stream.append(Self.speech(3))
        #expect(try #require(await finish(stream)).get().text == "W0 W1 w2.", "Casing comes from the snapshot taken at open")
        #expect(apps.withLock { $0 } == ["com.example.chat"])
        #expect(await transcribe(engine, Self.speech(3)) == .success("W0 w1 w2."), "A retry reads the dictionary again")
        #expect(apps.withLock { $0 } == ["com.example.chat", nil], "A retry uses the words for no app")
    }

    // MARK: - Retention and corrections

    private func retained(_ engine: SpeechEngine, seconds: Double = 3, app: String? = nil) async throws -> SpeechResult {
        let stream = engine.openStream(SpeechStreamOptions(appBundleID: app, retainForCorrection: true))
        stream.append(Self.speech(seconds))
        return try #require(await finish(stream, within: 30)).get()
    }

    private func suggest(_ engine: SpeechEngine, _ id: UInt64, isLast: Bool = false,
                         ignore: Set<DictionaryKey> = [], check: CorrectionCheck? = nil) async -> DictionarySuggestion? {
        let check = check ?? engine.beginCorrectionCheck()
        return await within {
            await engine.suggestCorrection(typed: "W0 w1 w2.", edited: "W0 zorblax w2.", correctionID: id, ignore: ignore,
                                           isLast: isLast, check: check)
        } ?? nil
    }

    @Test func retainedAudioFindsTheSuggestion() async throws {
        let log = ModelLog()
        let engine = engine(log)
        let plain = engine.openStream(SpeechStreamOptions())
        plain.append(Self.speech(3))
        #expect(try #require(await finish(plain)).get().correctionID == nil, "Nothing is kept unless asked")

        let result = try await retained(engine)
        let id = try #require(result.correctionID)
        #expect(result.text == "W0 w1 w2.")
        #expect(await suggest(engine, id) == DictionarySuggestion(word: "zorblax", strength: 2, kind: .replace),
                "The lowest strength at which the audio decodes to the correction")
        #expect(await suggest(engine, id, isLast: true) != nil, "Checks of the same dictation reuse the audio")
        #expect(await suggest(engine, id) == nil, "The last check releases it")
        #expect(await suggest(engine, id &+ 1) == nil, "An unknown id finds nothing")
    }

    @Test func aNewerRecordingReleasesTheOlderOne() async throws {
        let log = ModelLog()
        let engine = engine(log)
        let first = try #require(try await retained(engine).correctionID)
        let second = try #require(try await retained(engine).correctionID)
        #expect(await suggest(engine, first) == nil, "A newer dictation replaces the older one")
        #expect(await suggest(engine, second) != nil)
        // A recording opened while an older one is still being transcribed: the older one's late result keeps nothing.
        let older = engine.openStream(SpeechStreamOptions(retainForCorrection: true))
        older.append(Self.speech(3))
        let newer = engine.openStream(SpeechStreamOptions(retainForCorrection: true))
        #expect(await suggest(engine, second) == nil, "Starting a recording releases the kept audio")
        #expect(try #require(await finish(older)).get().correctionID == nil, "A late result never replaces a newer one's")
        newer.append(Self.speech(3))
        let newestResult = try #require(await finish(newer)).get()
        let newest = try #require(newestResult.correctionID)
        #expect(await suggest(engine, newest) != nil)
        // A retry is not a recording and releases nothing.
        _ = await transcribe(engine, Self.speech(2))
        #expect(await suggest(engine, newest) != nil)
    }

    /// With the default lifetime, so that only the release or the discard can drop the kept audio.
    @Test func releasesAndDiscards() async throws {
        let log = ModelLog()
        let engine = engine(log)
        let id = try #require(try await retained(engine).correctionID)
        engine.releaseCorrection(id &- 1)
        #expect(await suggest(engine, id) != nil, "Releasing another id never drops this one")
        engine.releaseCorrection(id)
        #expect(await suggest(engine, id) == nil, "Released")

        let discarded = try #require(try await retained(engine).correctionID)
        engine.discardCorrection()
        #expect(await suggest(engine, discarded) == nil, "Discarded")

        // A discard while a dictation is still being transcribed keeps nothing for it either.
        let late = engine.openStream(SpeechStreamOptions(retainForCorrection: true))
        late.append(Self.speech(3))
        engine.discardCorrection()
        #expect(try #require(await finish(late)).get().correctionID == nil)
    }

    @Test func keptAudioExpires() async throws {
        let log = ModelLog()
        let engine = engine(log, lifetime: 0.3)
        let expiring = try #require(try await retained(engine).correctionID)
        try await Task.sleep(for: .milliseconds(450))
        #expect(await suggest(engine, expiring) == nil, "Kept audio expires")
    }

    @Test func retentionHasLimits() async throws {
        let log = ModelLog()
        let engine = engine(log)
        // The fake keeps 4 bytes a sample, so 16 MiB is about 262 s of audio.
        let long = try await retained(engine, seconds: 270)
        #expect(long.correctionID == nil, "Over the limit nothing is kept")
        #expect(long.text == Self.words(seconds: 270), "but the dictation is still transcribed")
        let silent = engine.openStream(SpeechStreamOptions(retainForCorrection: true))
        silent.append(Signals.zeros(2))
        #expect(await finish(silent) == .success(SpeechResult(text: "")), "Nothing heard keeps nothing")
    }

    /// A cancel that lands after the result was made, before it was handed over, keeps nothing: nobody will see it.
    @Test func cancelAfterRetainingKeepsNothing() async throws {
        let log = ModelLog()
        let streams = Mutex<[UInt64: any SpeechStreaming]>([:])
        let engine = SpeechEngine(loader: fakeLoader(log), dictionary: { _ in .empty }, beforeDelivery: { id in
            streams.withLock { $0[id] }?.cancel()
        })
        let stream = engine.openStream(SpeechStreamOptions(retainForCorrection: true))
        let id = try #require((stream as? SpeechStream)?.id)
        streams.withLock { $0[id] = stream }
        stream.append(Self.speech(3))
        #expect(await finish(stream) == .failure(.cancelled))
        #expect(await within { await engine.heldProjections() } == 0, "The retained audio was released")
        #expect(await suggest(engine, id) == nil)
    }

    /// Releasing voids retention at once and frees what dictations still being recorded have collected, and they
    /// collect nothing more.
    @Test func releasingFreesAudioStillBeingCollected() async throws {
        for release in ["discard", "newer recording"] {
            let log = ModelLog()
            let engine = engine(log)
            await prepare(engine)
            let stream = engine.openStream(SpeechStreamOptions(retainForCorrection: true))
            stream.append(Self.speech(30))
            let deadline = ContinuousClock.now + .seconds(10)
            while log.projected.count < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(await within { await engine.heldProjections() } == 2, "\(release): two chunks collected")
            if release == "discard" { engine.discardCorrection() } else { _ = engine.openStream(SpeechStreamOptions()) }
            let freed = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < freed {
                let held = await within { await engine.heldProjections() }
                if held == 0 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await within { await engine.heldProjections() } == 0, "\(release): freed")
            stream.append(Self.speech(15))
            let more = ContinuousClock.now + .seconds(10)
            while log.projected.count < 3 && ContinuousClock.now < more { try await Task.sleep(for: .milliseconds(5)) }
            #expect(await within { await engine.heldProjections() } == 0, "\(release): nothing more is collected")
            #expect(try #require(await finish(stream)).get().correctionID == nil)
        }
    }

    /// Audio dropped because preparation failed is never followed by a partial transcript, even if a retry readies
    /// the model before the stream finishes.
    @Test func audioLostToAFailedPreparationFailsTheStream() async throws {
        let log = ModelLog()
        let release = DispatchSemaphore(value: 0)
        let engine = engine(log, loader: fakeLoader(log, failures: 1, wait: release))
        let stream = engine.openStream(SpeechStreamOptions())
        stream.append(Self.speech(3))
        release.signal()
        let failed = ContinuousClock.now + .seconds(10)
        while engine.preparation.outcome == nil && ContinuousClock.now < failed { try await Task.sleep(for: .milliseconds(5)) }
        #expect(engine.preparation.outcome == .failed(.loadFailed))
        try await Task.sleep(for: .milliseconds(50))
        release.signal()
        await prepare(engine)
        stream.append(Self.speech(2))
        #expect(await finish(stream) == .failure(.engineUnavailable(.loadFailed)))
    }

    /// A failure latched while a finish already waits (an older drain learning that its attempt failed, while the
    /// finish waits for a retry) reaches that finish at once, not when the retry ends.
    @Test func aLatchedFailureWakesAWaitingFinish() async throws {
        let log = ModelLog()
        let release = DispatchSemaphore(value: 0)
        let engine = engine(log, loader: fakeLoader(log, wait: release))
        let stream = engine.openStream(SpeechStreamOptions())
        let pending = Task { await finish(stream) }
        let installed = ContinuousClock.now + .seconds(5)
        while engine.preparation.waiting == 0 && ContinuousClock.now < installed { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        try #require(stream as? SpeechStream).fail(.engineUnavailable(.modelCorrupt))
        #expect(await within { await pending.value } == .failure(.engineUnavailable(.modelCorrupt)))
        #expect(elapsed(since: start) < .milliseconds(500), "The finish did not wait for the attempt in progress")
        try #require(stream as? SpeechStream).fail(.engineUnavailable(.loadFailed))
        release.signal()
        await prepare(engine)
        // A stream that failed before it finished refuses the finish with the first failure.
        let early = engine.openStream(SpeechStreamOptions())
        try #require(early as? SpeechStream).fail(.engineUnavailable(.loadFailed))
        early.append(Self.speech(1))
        #expect(await finish(early) == .failure(.engineUnavailable(.loadFailed)))
    }

    /// Someone waiting for an attempt hears how that attempt ended, even when a retry starts before they resume, and
    /// only a caller that asks to retry starts a new attempt after a failure.
    @Test func waitersHearTheirOwnAttempt() async {
        let preparation = Preparation()
        let first = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<EngineReadiness, Never>) in
                #expect(preparation.join(continuation, retryAfterFailure: true) == .started)
            }
        }
        let started = ContinuousClock.now + .seconds(5)
        while preparation.waiting == 0 && ContinuousClock.now < started { await Task.yield() }
        let waiters = preparation.finish(.failed(.loadFailed))
        // A retry begins before the first waiter has been resumed.
        let retry = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<EngineReadiness, Never>) in
                #expect(preparation.join(continuation, retryAfterFailure: true) == .started)
            }
        }
        let joined = ContinuousClock.now + .seconds(5)
        while preparation.waiting == 0 && ContinuousClock.now < joined { await Task.yield() }
        #expect(waiters.count == 1, "The failed attempt hands back only its own waiter")
        for waiter in waiters { waiter.resume(returning: .failed(.loadFailed)) }
        #expect(await within { await first.value } == .failed(.loadFailed))
        for waiter in preparation.finish(.ready) { waiter.resume(returning: .ready) }
        #expect(await within { await retry.value } == .ready)

        let failed = Preparation()
        let attempt = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<EngineReadiness, Never>) in
                _ = failed.join(continuation, retryAfterFailure: true)
            }
        }
        let begun = ContinuousClock.now + .seconds(5)
        while failed.waiting == 0 && ContinuousClock.now < begun { await Task.yield() }
        for waiter in failed.finish(.failed(.modelCorrupt)) { waiter.resume(returning: .failed(.modelCorrupt)) }
        _ = await within { await attempt.value }
        // A stream waiting for the model reports the failure instead of starting a new attempt.
        let decided = await within { () -> EngineReadiness in
            await withCheckedContinuation { (continuation: CheckedContinuation<EngineReadiness, Never>) in
                switch failed.join(continuation, retryAfterFailure: false) {
                case .done(let outcome): continuation.resume(returning: outcome)
                case .joined, .started: for waiter in failed.finish(.preparing) { waiter.resume(returning: .preparing) }
                }
            }
        }
        #expect(decided == .failed(.modelCorrupt))
    }

    /// Checks are ordered when registered, not when their work starts, and cancelling the calling task cancels its
    /// check.
    @Test func correctionChecksKeepTheirOrder() async throws {
        let log = ModelLog()
        let engine = engine(log)
        let id = try #require(try await retained(engine).correctionID)
        let older = engine.beginCorrectionCheck()
        let newer = engine.beginCorrectionCheck()
        #expect(older.isCancelled && !newer.isCancelled, "Registering a newer check cancels the older one")
        #expect(await suggest(engine, id, check: older) == nil, "The older check offers nothing")
        #expect(!newer.isCancelled, "The older check's late start leaves the newer one running")

        let latest = engine.beginCorrectionCheck()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.suggestCorrection(typed: "W0 w1 w2.", edited: "W0 zorblax w2.", correctionID: id,
                                                  ignore: [], isLast: false, check: latest)
        }
        #expect(await within { await cancelled.value } == .some(nil))
        #expect(latest.isCancelled, "Cancelling the calling task cancels its check")

        let running = engine.beginCorrectionCheck()
        _ = engine.openStream(SpeechStreamOptions())
        #expect(running.isCancelled, "Starting a recording cancels a running check")
    }

    @Test func ignoredAndKnownWordsAreNotSuggested() async throws {
        let log = ModelLog()
        let engine = engine(log)
        let id = try #require(try await retained(engine).correctionID)
        #expect(await suggest(engine, id, ignore: [DictionaryKey("zorblax")]) == nil)
        let known = self.engine(log, snapshot: DictionarySnapshot(revision: 1, entries: [DictionaryEntry(text: "zorblax", strength: 1)]))
        let knownID = try #require(try await retained(known).correctionID)
        #expect(await suggest(known, knownID) == nil, "A word already in the dictation's dictionary is not offered")
    }

    // MARK: - Find strength

    @Test func probeStrength() async throws {
        let log = ModelLog()
        let engine = engine(log)
        func probe(_ word: String, _ seconds: Double = 3) async -> Result<StrengthProbe.Result, SpeechFailure>? {
            await within {
                do throws(SpeechFailure) {
                    return .success(try await engine.probeStrength(samples: Self.speech(seconds), word: word))
                } catch {
                    return .failure(error)
                }
            }
        }
        #expect(await probe("zorblax") == .success(StrengthProbe.Result(outcome: .recognized(strength: 2), base: "W0 w1 w2.",
                                                                        boosted: "W0 zorblax w2.")))
        #expect(try #require(await probe("w2")).get().outcome == .alreadyRecognized)
        #expect(await probe("  ", 1) == .failure(.failed))
    }

    // MARK: - Graph cache

    @Test func graphCache() {
        let entries = [DictionaryEntry(text: "zorblax", strength: 1)]
        let encoder = BPEEncoder(pieces: FakeModel.pieces)
        var builds = 0
        var cache = BiasGraphCache()
        func graph(_ revision: UInt64, _ appID: String?, entries: [DictionaryEntry] = entries) -> BiasGraph? {
            cache.graph(for: DictionarySnapshot(revision: revision, entries: entries, appID: appID)) {
                builds += 1
                return BiasGraph.build(entries: entries, encoder: encoder)
            }
        }
        #expect(graph(1, nil, entries: []) == nil && builds == 0, "An empty snapshot has no graph and builds nothing")
        #expect(graph(1, nil) != nil, "Built")
        _ = graph(1, nil)
        #expect(builds == 1)
        _ = graph(1, "com.example.chat")
        _ = graph(1, "com.example.mail")
        _ = graph(1, "com.example.chat")
        _ = graph(1, nil)
        #expect(builds == 3)
        // Up to 4 graphs; the least recently used goes first.
        _ = graph(1, "com.example.notes")
        _ = graph(1, "com.example.fourth")
        #expect(builds == 5)
        _ = graph(1, "com.example.mail")
        #expect(builds == 6)
        _ = graph(1, "com.example.notes")
        _ = graph(1, "com.example.fourth")
        _ = graph(1, nil)
        #expect(builds == 6)
        // A new revision drops every older graph.
        _ = graph(2, nil)
        _ = graph(2, "com.example.chat")
        #expect(builds == 8)
        _ = graph(1, nil)
        #expect(builds == 9)
    }
}
