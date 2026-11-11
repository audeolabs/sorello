import DictationCore
import DictionaryKit
import Foundation
import Synchronization

/// Loads the model on the engine's executor, or says why it cannot.
typealias ModelLoader = @Sendable () throws(EngineFailure) -> any SpeechModel
/// Looks for the model on the engine's executor, each time it is asked to prepare: how to load it, or nil when it is
/// not on this Mac.
typealias ModelLocator = @Sendable () -> ModelLoader?

/// Turns speech into text with the pinned model (ARCHITECTURE.md, sections 4 and 5).
///
/// The engine is an actor with its own serial executor, a dispatch queue, so blocking Core ML and Accelerate calls
/// never occupy the cooperative thread pool. Model loading, warm-up, every prediction and every decode run there, one
/// at a time. Streams are objects of their own with a synchronized ingress in front of that executor, so opening one,
/// appending to it and cancelling it never wait for the model.
///
/// For correction suggestions the engine keeps, in memory only, what it needs to decode one dictation again: the
/// most recent recording that asked for it. Opening a newer recording, `discardCorrection()` and the watch ending
/// release it, and a late result from an older recording never replaces a newer one's.
public actor SpeechEngine: SpeechTranscribing {
    /// Retained audio over this size is not kept; the dictation is still transcribed.
    static let retainedBytesLimit = 16 << 20

    private let queue = DispatchSerialQueue(label: "sorello.speech", qos: .userInitiated)
    /// Where the encoder runs, chosen when the engine was made. The General screen says which one this Mac uses.
    public nonisolated let compute: SpeechCompute
    private let locate: ModelLocator
    private let dictionary: @Sendable (String?) -> DictionarySnapshot
    private let retainedLifetime: TimeInterval
    private let beforeDelivery: (@Sendable (UInt64) -> Void)?
    private let readinessHub: ReadinessHub
    nonisolated let preparation = Preparation()
    private let gate = RetentionGate()
    private let checks = CheckRegistry()

    private var model: (any SpeechModel)?
    private var graphs = BiasGraphCache()
    private var work: [UInt64: StreamWork] = [:]
    private var retained: RetainedCorrection?
    private var expiry: Task<Void, Never>?

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// The engine the app uses (ARCHITECTURE.md, section 5, "Getting the model"). Each time it is asked to prepare it
    /// looks for `model`'s build: in the store, then in the app when the app carries it, which is copied to the store
    /// once. Until it finds it, the engine is `failed(.modelMissing)`, so it becomes ready without a relaunch once a
    /// download has put the model in the store.
    /// - `compute`: where the encoder runs. The default reads this Mac's hardware, once, now; the verification tools
    ///   pass `.cpu` to prove the fallback on a Mac that has a Neural Engine.
    /// - `dictionary`: the words for a dictation into an app (nil: no app), read once when its stream opens.
    public init(model: PinnedModel, compute: SpeechCompute = .forThisMac(),
                dictionary: @escaping @Sendable (String?) -> DictionarySnapshot) {
        self.init(locate: Self.locator(model, compute: compute), present: model.isOnThisMac, compute: compute,
                  dictionary: dictionary)
    }

    /// An engine for a model bundle given directly, as `sorello-transcribe --model` gives one.
    /// - `modelDirectory`: the bundle; nil gives the engine nowhere to look, so it stays `failed(.modelMissing)`.
    /// - `storeDirectory`: where the stable copy of the bundle is kept, so the Neural Engine's compiled model survives
    ///   a rebuild; nil loads straight from `modelDirectory`. The CPU fallback loads the same copy, so both paths
    ///   check the same files and share one store.
    public init(modelDirectory: URL?, storeDirectory: URL?, compute: SpeechCompute = .forThisMac(),
                dictionary: @escaping @Sendable (String?) -> DictionarySnapshot) {
        let loader = modelDirectory.map { bundle in
            Self.loader(bundle: bundle, store: storeDirectory.map { ModelStore(root: $0) }, compute: compute)
        }
        self.init(loader: loader, compute: compute, dictionary: dictionary)
    }

    /// An engine whose model is always `loader`, or never there when it is nil.
    init(loader: ModelLoader?, compute: SpeechCompute = .neuralEngine,
         dictionary: @escaping @Sendable (String?) -> DictionarySnapshot,
         retainedLifetime: TimeInterval = 90, beforeDelivery: (@Sendable (UInt64) -> Void)? = nil) {
        self.init(locate: { loader }, present: loader != nil, compute: compute, dictionary: dictionary,
                  retainedLifetime: retainedLifetime, beforeDelivery: beforeDelivery)
    }

    /// `present` says whether the model looks to be there now, which decides the first readiness: `preparing`, or
    /// `failed(.modelMissing)`. `beforeDelivery` runs on the engine's executor after a stream's result is made and
    /// before it is handed over, so tests can land a cancel there.
    init(locate: @escaping ModelLocator, present: Bool, compute: SpeechCompute = .neuralEngine,
         dictionary: @escaping @Sendable (String?) -> DictionarySnapshot,
         retainedLifetime: TimeInterval = 90, beforeDelivery: (@Sendable (UInt64) -> Void)? = nil) {
        self.compute = compute
        self.beforeDelivery = beforeDelivery
        self.locate = locate
        self.dictionary = dictionary
        self.retainedLifetime = retainedLifetime
        readinessHub = ReadinessHub(present ? .preparing : .failed(.modelMissing))
    }

    /// Where `model` is, looked for afresh each time: the store's complete copy, else the app's own copy installed
    /// into the store (or loaded in place when the store cannot take it), else nothing.
    static func locator(_ model: PinnedModel, compute: SpeechCompute) -> ModelLocator {
        let store = ModelStore(root: model.storeDirectory)
        return { () -> ModelLoader? in
            guard let identity = model.build?.manifestSHA256 else { return nil }
            let carried = model.carriedDirectory
            if let stored = store.stored(identity) {
                return storedLoader(stored, store: store, carried: carried, compute: compute)
            }
            guard let carried else { return nil }
            if let installed = store.install(bundle: carried, as: identity) {
                return storedLoader(installed, store: store, carried: carried, compute: compute)
            }
            return { () throws(EngineFailure) -> any SpeechModel in try load(carried, compute: compute) }
        }
    }

    /// Loads the store's copy. Files that do not match the manifest are removed with the copy; then the app's own
    /// copy is loaded in place if it has one, and otherwise the model is missing again, so it can be downloaded
    /// again. A copy whose files are right but which Core ML will not load is kept and reported, unless the app's
    /// own copy can stand in for it.
    private static func storedLoader(_ directory: URL, store: ModelStore, carried: URL?,
                                     compute: SpeechCompute) -> ModelLoader {
        { () throws(EngineFailure) -> any SpeechModel in
            let model: CoreMLSpeechModel
            do {
                model = try CoreMLSpeechModel(directory: directory, compute: compute)
            } catch {
                store.discard(directory)
                guard let carried else { throw .modelMissing }
                store.disable()
                return try load(carried, compute: compute)
            }
            do throws(EngineFailure) {
                try model.prepare()
                return model
            } catch {
                guard let carried else { throw error }
                store.disable()
                store.discard(directory)
                return try load(carried, compute: compute)
            }
        }
    }

    /// The model at `directory`, verified and warmed.
    private static func load(_ directory: URL, compute: SpeechCompute) throws(EngineFailure) -> any SpeechModel {
        let model = try CoreMLSpeechModel(directory: directory, compute: compute)
        try model.prepare()
        return model
    }

    /// A model bundle given directly, on `compute`, from the store's stable copy when there is one.
    private static func loader(bundle: URL, store: ModelStore?, compute: SpeechCompute) -> ModelLoader {
        { () throws(EngineFailure) -> any SpeechModel in
            guard let store else {
                let model = try CoreMLSpeechModel(directory: bundle, compute: compute)
                try model.prepare()
                return model
            }
            do {
                return try store.open(bundle: bundle, make: { try CoreMLSpeechModel(directory: $0, compute: compute) },
                                      prepare: { try $0.prepare() })
            } catch let failure as EngineFailure {
                throw failure
            } catch {
                throw .loadFailed
            }
        }
    }

    // MARK: - Readiness

    /// Loads and warms the model, or tries again after a failure. Returns when the engine is ready or has failed.
    /// Concurrent calls share one attempt: a call joins the attempt in progress the moment it is made, even while
    /// the engine's executor is busy loading, and only a call made after an attempt has ended starts a new one.
    public nonisolated func prepare() async {
        _ = await joinPreparation(retryAfterFailure: true)
    }

    /// Joins the attempt in progress, or starts one, and returns how that attempt ended. Without
    /// `retryAfterFailure`, a failed last attempt is returned as it is instead of starting a new one.
    private nonisolated func joinPreparation(retryAfterFailure: Bool) async -> EngineReadiness {
        await withCheckedContinuation { (continuation: CheckedContinuation<EngineReadiness, Never>) in
            switch preparation.join(continuation, retryAfterFailure: retryAfterFailure) {
            case .done(let outcome):
                continuation.resume(returning: outcome)
            case .joined:
                break
            case .started:
                // An engine without its model says it is preparing only once it has found the model.
                if readinessHub.current != .failed(.modelMissing) { readinessHub.publish(.preparing) }
                Task { await self.runPreparation() }
            }
        }
    }

    /// The current readiness, then every change, for each caller separately.
    public nonisolated func readiness() -> AsyncStream<EngineReadiness> { readinessHub.subscribe() }

    private func runPreparation() {
        let started = ContinuousClock.now
        let outcome: EngineReadiness
        if let loader = locate() {
            readinessHub.publish(.preparing)
            do {
                model = try loader()
                Diagnostics.record("speech.prepared", ["seconds": Self.seconds(since: started)])
                outcome = .ready
            } catch {
                Diagnostics.record("speech.preparationFailed", ["seconds": Self.seconds(since: started)])
                outcome = .failed(error)
            }
        } else {
            Diagnostics.record("speech.modelMissing")
            outcome = .failed(.modelMissing)
        }
        readinessHub.publish(outcome)
        for waiter in preparation.finish(outcome) { waiter.resume(returning: outcome) }
    }

    /// The model, once preparation has succeeded. Waits behind an attempt in progress and starts one if none was
    /// ever made; after a failed attempt it throws until `prepare` is called again. A caller that waited for an
    /// attempt gets that attempt's outcome, even if a retry has started since.
    private func readyModel() async throws(SpeechFailure) -> any SpeechModel {
        if let model { return model }
        // One step decides whether to wait, start the first attempt, or report the last failure, so a stream never
        // starts a new attempt after one has failed.
        if case .failed(let failure) = await joinPreparation(retryAfterFailure: false) {
            throw .engineUnavailable(failure)
        }
        // A successful attempt sets the model before it resumes anyone.
        guard let model else { throw .failed }
        return model
    }

    // MARK: - Streams

    /// Opens a stream for one dictation, taking the dictionary snapshot for its app now. Starting a recording
    /// releases the audio kept for an older dictation's correction and stops its check.
    public nonisolated func openStream(_ options: SpeechStreamOptions) -> any SpeechStreaming {
        makeStream(options, recording: true)
    }

    /// Transcribes a whole recording, as a Run Log retry does: with the dictionary's words that apply everywhere
    /// unless `appBundleID` says otherwise, and keeping nothing for corrections. Waits for preparation like a stream.
    public nonisolated func transcribe(_ samples: [Float], appBundleID: String? = nil) async throws(SpeechFailure) -> String {
        let stream = makeStream(SpeechStreamOptions(appBundleID: appBundleID), recording: false)
        stream.append(samples)
        do {
            return try await stream.finish().text
        } catch let failure as SpeechFailure {
            throw failure
        } catch {
            throw .failed
        }
    }

    private nonisolated func makeStream(_ options: SpeechStreamOptions, recording: Bool) -> SpeechStream {
        let id = gate.open(recording: recording)
        if recording {
            checks.cancelCurrent()
            Task { await self.dropStaleRetention() }
        }
        return SpeechStream(id: id, engine: self, snapshot: dictionary(options.appBundleID),
                            retainsAudio: options.retainForCorrection)
    }

    /// Stops a running correction check, so finishing a dictation never waits behind one.
    nonisolated func cancelChecks() { checks.cancelCurrent() }

    /// Transcribes what a stream has been handed so far, while the user is still speaking.
    func drain(_ stream: SpeechStream) async {
        let model: any SpeechModel
        do {
            model = try await readyModel()
        } catch {
            // This audio will never be transcribed, so the stream can never succeed, even if a retry readies the
            // model before it finishes: finishing reports why.
            stream.fail(error)
            return
        }
        // A finishing stream's remaining audio is completed by `complete`.
        guard !stream.isCancelled, !stream.isFinishing else { return }
        let work = self.work(for: stream, model: model)
        let samples = stream.takeInbox()
        guard !samples.isEmpty, work.failure == nil else { return }
        let check = stream.cancellationCheck, gate = self.gate
        do {
            try work.transcription.append(samples) {
                try Self.transcribe($0, work: work, model: model, gate: gate, check: check)
            }
        } catch {
            work.failure = Self.failure(error)
        }
    }

    /// Finishes a stream and hands its waiting `finish` the result, unless it was cancelled meanwhile; then what the
    /// result retained is released, because nobody will ever see it.
    func complete(_ stream: SpeechStream) async {
        let outcome: Result<SpeechResult, SpeechFailure>
        do throws(SpeechFailure) {
            outcome = .success(try await finishWork(stream))
        } catch {
            outcome = .failure(error)
        }
        work[stream.id] = nil
        beforeDelivery?(stream.id)
        if !stream.deliver(outcome), case .success(let result) = outcome, let id = result.correctionID {
            release(id)
        }
    }

    /// A cancelled stream's partial work is dropped.
    func forget(_ id: UInt64) {
        work[id] = nil
    }

    private func finishWork(_ stream: SpeechStream) async throws(SpeechFailure) -> SpeechResult {
        if let failure = stream.failure { throw failure }
        let model = try await readyModel()
        guard !stream.isCancelled else { throw .cancelled }
        if let failure = stream.failure { throw failure }
        let work = self.work(for: stream, model: model)
        let samples = stream.takeInbox()
        if let failure = work.failure { throw failure }
        let check = stream.cancellationCheck, gate = self.gate
        do {
            if !samples.isEmpty {
                try work.transcription.append(samples) {
                    try Self.transcribe($0, work: work, model: model, gate: gate, check: check)
                }
            }
            let raw = try work.transcription.finish {
                try Self.transcribe($0, work: work, model: model, gate: gate, check: check)
            }
            try check()
            let text = CasingRestorer.apply(raw, entries: work.snapshot.entries)
            return SpeechResult(text: text, correctionID: retain(work, id: stream.id, model: model, base: text))
        } catch {
            throw Self.failure(error)
        }
    }

    /// The stream's model-side state, made when the model first works on it: its bias graph is fixed then, from the
    /// snapshot taken when it opened.
    private func work(for stream: SpeechStream, model: any SpeechModel) -> StreamWork {
        if let existing = work[stream.id] { return existing }
        let snapshot = stream.snapshot
        let bias = graphs.graph(for: snapshot) { BiasGraph.build(entries: snapshot.entries, encoder: model.encoder) }
        let created = StreamWork(id: stream.id, snapshot: snapshot, bias: bias, retainsAudio: stream.retainsAudio)
        work[stream.id] = created
        return created
    }

    /// One chunk's words. With retention on, its projection is kept, until the dictation's projections pass the size
    /// limit or its retention is voided (a newer recording, a release); then nothing more is kept, but transcription
    /// goes on. A nil `gate` keeps everything, for find strength, which is not a recording.
    private static func transcribe(_ window: AudioWindow, work: StreamWork, model: any SpeechModel, gate: RetentionGate?,
                                   check: () throws -> Void) throws -> [HeardWord] {
        if work.retained != nil, let gate, !gate.allows(work.id) { work.retained = nil }
        let projection = try model.project(window.samples, check: check)
        work.retained?.chunks.append(RetainedChunk(range: window.range, projection: projection))
        work.retained?.bytes += projection?.bytes ?? 0
        if let bytes = work.retained?.bytes, bytes > retainedBytesLimit { work.retained = nil }
        guard let projection else { return [] }
        return try model.decode(projection, offset: window.start, bias: work.bias, check: check)
    }

    private static func failure(_ error: any Error) -> SpeechFailure {
        if let failure = error as? SpeechFailure { return failure }
        if error as? TranscriptionError == .cancelled { return .cancelled }
        return .failed
    }

    // MARK: - Corrections

    /// Keeps a finished dictation's audio for correction checks, if it asked, the audio fit, it has text, and no newer
    /// recording or release has happened since it opened. Returns the id the result carries.
    private func retain(_ work: StreamWork, id: UInt64, model: any SpeechModel, base: String) -> UInt64? {
        guard let audio = work.retained, !base.isEmpty, gate.allows(id) else { return nil }
        retained = RetainedCorrection(id: id, model: model, chunks: audio.chunks, snapshot: work.snapshot, base: base,
                                      deadline: Self.uptime() + retainedLifetime)
        expiry?.cancel()
        let lifetime = retainedLifetime
        expiry = Task {
            try? await Task.sleep(for: .seconds(lifetime))
            if !Task.isCancelled { self.release(id) }
        }
        return id
    }

    /// Registers a correction check now, cancelling any older one. Call it when the check is decided, so checks keep
    /// that order however late their work starts.
    public nonisolated func beginCorrectionCheck() -> CorrectionCheck { checks.begin() }

    /// Looks for a word to suggest from a correction the user made to a dictation (DESIGN §1.5 and §1.6), decoding
    /// that dictation's retained audio again with each candidate. Returns nil when there is none, and when the
    /// audio is no longer kept, a newer check was registered, a newer recording started, or the calling task was
    /// cancelled. With `isLast` (the watch has ended) the audio is released afterwards.
    public func suggestCorrection(typed: String, edited: String, correctionID: UInt64, ignore: Set<DictionaryKey>,
                                  isLast: Bool, check: CorrectionCheck) async -> DictionarySuggestion? {
        let token = check.token
        let gate = self.gate
        func cancelled() -> Bool {
            if Task.isCancelled { token.cancel() }
            return token.isCancelled || !gate.allows(correctionID)
        }
        guard !cancelled(), let session = liveSession(correctionID) else { return nil }
        let model = session.model
        let suggestion = DictionarySuggestionFinder.find(
            typed: typed, edited: edited, base: session.base, dictionary: session.snapshot.entries, ignore: ignore,
            encoder: model.encoder, exhausted: session.exhausted, now: { Self.uptime() }, isCancelled: cancelled,
            decode: { extra in
                let entries = session.snapshot.entries.filter { $0.key != extra.key } + [extra]
                guard let graph = BiasGraph.build(entries: entries, encoder: model.encoder),
                      let text = try? Self.decode(session.chunks, model: model, bias: graph, check: {
                          if cancelled() { throw TranscriptionError.cancelled }
                      }) else {
                    return nil
                }
                return CasingRestorer.apply(text, entries: entries)
            })
        let stopped = cancelled()
        // After the last check nothing else can use this dictation's audio.
        if isLast && !stopped { release(correctionID) }
        return stopped ? nil : suggestion
    }

    /// Releases the audio kept for any dictation and stops a running check: clearing the Run Log, turning suggestions
    /// off, or a dictionary change. A dictation still being transcribed keeps nothing either.
    public nonisolated func discardCorrection() {
        gate.releaseAll()
        checks.cancelCurrent()
        Task { await self.dropStaleRetention() }
    }

    /// Releases one dictation's audio, never a newer one's: the watch for it ended or found nothing to watch.
    public nonisolated func releaseCorrection(_ correctionID: UInt64) {
        gate.release(correctionID)
        Task { await self.release(correctionID) }
    }

    private func release(_ id: UInt64) {
        guard retained?.id == id else { return }
        retained = nil
        expiry?.cancel()
        expiry = nil
    }

    /// Frees what voided retention held: the finished dictation's audio, and what dictations still being
    /// transcribed had collected.
    private func dropStaleRetention() {
        if let id = retained?.id, !gate.allows(id) { release(id) }
        for (id, stream) in work where stream.retained != nil && !gate.allows(id) { stream.retained = nil }
    }

    /// The projections kept for corrections, finished or in progress, so tests can see that releasing frees them.
    func heldProjections() -> Int {
        let finished = retained?.chunks.count(where: { $0.projection != nil }) ?? 0
        return work.values.reduce(finished) { held, stream in
            held + (stream.retained?.chunks.count(where: { $0.projection != nil }) ?? 0)
        }
    }

    private func liveSession(_ id: UInt64) -> RetainedCorrection? {
        guard let session = retained, session.id == id, gate.allows(id) else { return nil }
        guard Self.uptime() < session.deadline else {
            release(id)
            return nil
        }
        return session
    }

    /// Re-decodes retained chunks exactly as they were transcribed, with a new bias.
    private static func decode(_ chunks: [RetainedChunk], model: any SpeechModel, bias: BiasGraph?,
                               check: () throws -> Void) throws -> String {
        var transcript = TranscriptAssembler()
        for chunk in chunks {
            let words = try chunk.projection.map {
                try model.decode($0, offset: chunk.range.lowerBound, bias: bias, check: check)
            } ?? []
            transcript.append(words, covering: chunk.range)
        }
        return transcript.text
    }

    // MARK: - Find strength

    /// "Find strength" (DESIGN, platform differences): transcribes `samples` with the dictionary for `appBundleID`
    /// minus `word`, then decodes the same audio again with `word` added at each verification strength until one is
    /// accepted. Audio and text stay in memory and are released when this returns. Throws `failed` when `word` is not
    /// a valid entry or the recording is too long to keep, and `cancelled` when the calling task is cancelled.
    public func probeStrength(samples: [Float], word: String,
                              appBundleID: String? = nil) async throws(SpeechFailure) -> StrengthProbe.Result {
        let model = try await readyModel()
        guard case .success(let entry) = DictionaryValidation.validate(text: word, strength: 1, encoder: model.encoder) else {
            throw .failed
        }
        let check: () throws -> Void = { if Task.isCancelled { throw TranscriptionError.cancelled } }
        let others = dictionary(appBundleID).entries.filter { $0.key != entry.key }
        let work = StreamWork(id: 0, snapshot: DictionarySnapshot(revision: 0, entries: others),
                              bias: BiasGraph.build(entries: others, encoder: model.encoder), retainsAudio: true)
        do {
            try work.transcription.append(samples) {
                try Self.transcribe($0, work: work, model: model, gate: nil, check: check)
            }
            let raw = try work.transcription.finish {
                try Self.transcribe($0, work: work, model: model, gate: nil, check: check)
            }
            guard let audio = work.retained else { throw SpeechFailure.failed }
            let base = CasingRestorer.apply(raw, entries: others)
            return try StrengthProbe.find(word: entry.text, base: base) { strength in
                let entries = others + [DictionaryEntry(text: entry.text, strength: strength)]
                guard let graph = BiasGraph.build(entries: entries, encoder: model.encoder) else {
                    throw SpeechFailure.failed
                }
                return CasingRestorer.apply(try Self.decode(audio.chunks, model: model, bias: graph, check: check),
                                            entries: entries)
            }
        } catch {
            throw Self.failure(error)
        }
    }

    private static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

/// A registered correction check. Registering a newer one, starting a recording, finishing a dictation or
/// `discardCorrection()` cancels it.
public struct CorrectionCheck: Sendable {
    let token: CancellationToken

    public var isCancelled: Bool { token.isCancelled }
}

final class CancellationToken: Sendable {
    private let cancelled = Mutex(false)

    func cancel() { cancelled.withLock { $0 = true } }

    var isCancelled: Bool { cancelled.withLock { $0 } }
}

/// One correction check at a time; a newer one cancels the older.
final class CheckRegistry: Sendable {
    private let current = Mutex<CancellationToken?>(nil)

    func begin() -> CorrectionCheck {
        let token = CancellationToken()
        current.withLock { current in
            current?.cancel()
            current = token
        }
        return CorrectionCheck(token: token)
    }

    func cancelCurrent() {
        current.withLock { current in
            current?.cancel()
            current = nil
        }
    }
}

/// Which stream may keep audio for corrections, decided from any thread. Streams are numbered as they open; only the
/// newest recording may keep or use retained audio, and a release voids every stream opened before it.
final class RetentionGate: Sendable {
    private struct State {
        var next: UInt64 = 1
        var recording: UInt64 = 0
        var floor: UInt64 = 0
    }

    private let state = Mutex(State())

    func open(recording: Bool) -> UInt64 {
        state.withLock { state in
            let id = state.next
            state.next += 1
            if recording { state.recording = id }
            return id
        }
    }

    func allows(_ id: UInt64) -> Bool {
        state.withLock { $0.recording == id && id >= $0.floor }
    }

    func releaseAll() {
        state.withLock { $0.floor = $0.next }
    }

    /// Voids `id` and nothing newer.
    func release(_ id: UInt64) {
        state.withLock { $0.floor = max($0.floor, id &+ 1) }
    }
}

/// The state of preparation, decided under a lock so a caller joins the attempt in progress at once, even while
/// the engine's executor is busy loading the model.
final class Preparation: Sendable {
    enum Join: Equatable {
        /// No attempt runs, and the last one ended so; the caller resumes its waiter itself.
        case done(EngineReadiness)
        case joined
        case started
    }

    private struct State {
        /// nil before the first attempt ends, and while one is in progress.
        var outcome: EngineReadiness?
        var running = false
        var waiters: [CheckedContinuation<EngineReadiness, Never>] = []
    }

    private let state = Mutex(State())

    /// How many calls wait for the attempt in progress.
    var waiting: Int { state.withLock { $0.waiters.count } }

    /// How the last attempt ended, while none is in progress.
    var outcome: EngineReadiness? { state.withLock { $0.running ? nil : $0.outcome } }

    /// `done` when the model is ready, or when the last attempt failed and `retryAfterFailure` is false (the caller
    /// resumes `waiter` itself); otherwise `waiter` waits for the attempt in progress (`joined`), or for a new one the
    /// caller must start (`started`), and is resumed with how that attempt ended.
    func join(_ waiter: CheckedContinuation<EngineReadiness, Never>, retryAfterFailure: Bool) -> Join {
        state.withLock { state in
            if !state.running, let outcome = state.outcome {
                if outcome == .ready { return .done(.ready) }
                if !retryAfterFailure { return .done(outcome) }
            }
            state.waiters.append(waiter)
            if state.running { return .joined }
            state.running = true
            state.outcome = nil
            return .started
        }
    }

    /// Ends the attempt and hands back everyone waiting for it.
    func finish(_ outcome: EngineReadiness) -> [CheckedContinuation<EngineReadiness, Never>] {
        state.withLock { state in
            state.running = false
            state.outcome = outcome
            defer { state.waiters = [] }
            return state.waiters
        }
    }
}

/// The engine's readiness for every subscriber, each of which first hears the current value.
final class ReadinessHub: Sendable {
    private struct State {
        var current: EngineReadiness
        var subscribers: [UUID: AsyncStream<EngineReadiness>.Continuation] = [:]
    }

    private let state: Mutex<State>

    init(_ initial: EngineReadiness) {
        state = Mutex(State(current: initial))
    }

    /// The readiness last published.
    var current: EngineReadiness { state.withLock { $0.current } }

    func subscribe() -> AsyncStream<EngineReadiness> {
        let (stream, continuation) = AsyncStream<EngineReadiness>.makeStream()
        let id = UUID()
        state.withLock { state in
            continuation.yield(state.current)
            state.subscribers[id] = continuation
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Tells every subscriber, unless nothing changed.
    func publish(_ readiness: EngineReadiness) {
        state.withLock { state in
            guard state.current != readiness else { return }
            state.current = readiness
            for continuation in state.subscribers.values { continuation.yield(readiness) }
        }
    }
}

/// Bias graphs of the current dictionary revision, by app, least recently used first. A new revision drops the older
/// graphs (DESIGN §3.6). Used on the engine's executor only.
struct BiasGraphCache {
    static let capacity = 4

    private var revision: UInt64?
    private var graphs: [(appID: String?, graph: BiasGraph?)] = []

    /// An empty snapshot has no graph, so decoding takes the unbiased path.
    mutating func graph(for snapshot: DictionarySnapshot, build: () -> BiasGraph?) -> BiasGraph? {
        guard !snapshot.entries.isEmpty else { return nil }
        if revision != snapshot.revision {
            revision = snapshot.revision
            graphs.removeAll()
        }
        if let index = graphs.firstIndex(where: { $0.appID == snapshot.appID }) {
            let cached = graphs.remove(at: index)
            graphs.append(cached)
            return cached.graph
        }
        let graph = build()
        if graphs.count == Self.capacity { graphs.removeFirst() }
        graphs.append((snapshot.appID, graph))
        return graph
    }
}

/// One chunk's place in the recording, so re-decoding stitches overlaps exactly as the original transcription did.
/// A nil projection marks a silent chunk, which stitches as no words.
struct RetainedChunk {
    let range: Range<Int>
    let projection: Projection?
}

/// Every chunk of one dictation in order, and the memory they hold.
struct RetainedAudio {
    var chunks: [RetainedChunk] = []
    var bytes = 0
}

/// A stream's state on the engine's executor.
final class StreamWork {
    let id: UInt64
    let snapshot: DictionarySnapshot
    let bias: BiasGraph?
    var transcription = ChunkedTranscription.recording()
    var retained: RetainedAudio?
    var failure: SpeechFailure?

    init(id: UInt64, snapshot: DictionarySnapshot, bias: BiasGraph?, retainsAudio: Bool) {
        self.id = id
        self.snapshot = snapshot
        self.bias = bias
        retained = retainsAudio ? RetainedAudio() : nil
    }
}

/// The one dictation kept for correction checks.
final class RetainedCorrection {
    let id: UInt64
    let model: any SpeechModel
    let chunks: [RetainedChunk]
    let snapshot: DictionarySnapshot
    /// The transcript after casing restoration, before any text rule (DESIGN §1.6.1).
    let base: String
    let deadline: TimeInterval
    /// Shared by every check of this dictation.
    let exhausted = ExhaustedCandidates()

    init(id: UInt64, model: any SpeechModel, chunks: [RetainedChunk], snapshot: DictionarySnapshot, base: String,
         deadline: TimeInterval) {
        self.id = id
        self.model = model
        self.chunks = chunks
        self.snapshot = snapshot
        self.base = base
        self.deadline = deadline
    }
}
