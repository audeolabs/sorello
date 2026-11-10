import DictationCore
import DictionaryKit
import Foundation
import Synchronization

/// Loads the model on the engine's executor, or says why it cannot.
typealias ModelLoader = @Sendable () throws(EngineFailure) -> any SpeechModel

/// Turns speech into text with the bundled model (ARCHITECTURE.md, sections 4 and 5).
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
    private let loader: ModelLoader?
    private let dictionary: @Sendable (String?) -> DictionarySnapshot
    private let retainedLifetime: TimeInterval
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

    /// - `modelDirectory`: the model bundle in the app's resources; nil when the app was built without the model,
    ///   which makes the engine `failed(.modelMissing)` for good.
    /// - `storeDirectory`: where the stable copy of the model is kept (`Application Support/<bundle id>/Models`), so
    ///   the Neural Engine's compiled model survives app updates; nil loads straight from `modelDirectory`.
    /// - `dictionary`: the words for a dictation into an app (nil: no app), read once when its stream opens.
    public init(modelDirectory: URL?, storeDirectory: URL?,
                dictionary: @escaping @Sendable (String?) -> DictionarySnapshot) {
        let loader = modelDirectory.map { bundle in
            Self.loader(bundle: bundle, store: storeDirectory.map { ModelStore(root: $0) })
        }
        self.init(loader: loader, dictionary: dictionary)
    }

    init(loader: ModelLoader?, dictionary: @escaping @Sendable (String?) -> DictionarySnapshot,
         retainedLifetime: TimeInterval = 90) {
        self.loader = loader
        self.dictionary = dictionary
        self.retainedLifetime = retainedLifetime
        readinessHub = ReadinessHub(loader == nil ? .failed(.modelMissing) : .preparing)
    }

    /// The bundled model, from the store's stable copy when there is one.
    private static func loader(bundle: URL, store: ModelStore?) -> ModelLoader {
        { () throws(EngineFailure) -> any SpeechModel in
            guard let store else {
                let model = try CoreMLSpeechModel(directory: bundle)
                try model.prepare()
                return model
            }
            do {
                return try store.open(bundle: bundle, make: { try CoreMLSpeechModel(directory: $0) },
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
        guard loader != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            switch preparation.join(continuation) {
            case .done:
                continuation.resume()
            case .joined:
                break
            case .started:
                readinessHub.publish(.preparing)
                Task { await self.runPreparation() }
            }
        }
    }

    /// The current readiness, then every change, for each caller separately.
    public nonisolated func readiness() -> AsyncStream<EngineReadiness> { readinessHub.subscribe() }

    private func runPreparation() {
        guard let loader else { return }
        let started = ContinuousClock.now
        let outcome: EngineReadiness
        do {
            model = try loader()
            Diagnostics.record("speech.prepared", ["seconds": Self.seconds(since: started)])
            outcome = .ready
        } catch {
            Diagnostics.record("speech.preparationFailed", ["seconds": Self.seconds(since: started)])
            outcome = .failed(error)
        }
        readinessHub.publish(outcome)
        for waiter in preparation.finish(outcome) { waiter.resume() }
    }

    /// The model, once preparation has succeeded. Waits behind an attempt in progress and starts one if none was
    /// ever made; after a failed attempt it throws until `prepare` is called again.
    private func readyModel() async throws(SpeechFailure) -> any SpeechModel {
        while true {
            if let model { return model }
            guard loader != nil else { throw .engineUnavailable(.modelMissing) }
            if case .failed(let failure) = preparation.outcome { throw .engineUnavailable(failure) }
            await prepare()
        }
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
            // Without a model nothing will ever be transcribed; finishing reports why.
            _ = stream.takeInbox()
            return
        }
        // A finishing stream's remaining audio is completed by `complete`.
        guard !stream.isCancelled, !stream.isFinishing else { return }
        let work = self.work(for: stream, model: model)
        let samples = stream.takeInbox()
        guard !samples.isEmpty, work.failure == nil else { return }
        let check = stream.cancellationCheck
        do {
            try work.transcription.append(samples) { try Self.transcribe($0, work: work, model: model, check: check) }
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
        if !stream.deliver(outcome), case .success(let result) = outcome, let id = result.correctionID {
            release(id)
        }
    }

    /// A cancelled stream's partial work is dropped.
    func forget(_ id: UInt64) {
        work[id] = nil
    }

    private func finishWork(_ stream: SpeechStream) async throws(SpeechFailure) -> SpeechResult {
        let model = try await readyModel()
        guard !stream.isCancelled else { throw .cancelled }
        let work = self.work(for: stream, model: model)
        let samples = stream.takeInbox()
        if let failure = work.failure { throw failure }
        let check = stream.cancellationCheck
        do {
            if !samples.isEmpty {
                try work.transcription.append(samples) { try Self.transcribe($0, work: work, model: model, check: check) }
            }
            let raw = try work.transcription.finish { try Self.transcribe($0, work: work, model: model, check: check) }
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
        let created = StreamWork(snapshot: snapshot, bias: bias, retainsAudio: stream.retainsAudio)
        work[stream.id] = created
        return created
    }

    /// One chunk's words. With retention on, its projection is kept, until the dictation's projections pass the size
    /// limit; then nothing is kept, but transcription goes on.
    private static func transcribe(_ window: AudioWindow, work: StreamWork, model: any SpeechModel,
                            check: () throws -> Void) throws -> [HeardWord] {
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

    private func dropStaleRetention() {
        if let id = retained?.id, !gate.allows(id) { release(id) }
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
        let work = StreamWork(snapshot: DictionarySnapshot(revision: 0, entries: others),
                              bias: BiasGraph.build(entries: others, encoder: model.encoder), retainsAudio: true)
        do {
            try work.transcription.append(samples) { try Self.transcribe($0, work: work, model: model, check: check) }
            let raw = try work.transcription.finish { try Self.transcribe($0, work: work, model: model, check: check) }
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
    enum Join { case done, joined, started }

    private struct State {
        /// nil before the first attempt ends, and while one is in progress.
        var outcome: EngineReadiness?
        var running = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// How many calls wait for the attempt in progress.
    var waiting: Int { state.withLock { $0.waiters.count } }

    /// How the last attempt ended, while none is in progress.
    var outcome: EngineReadiness? { state.withLock { $0.running ? nil : $0.outcome } }

    /// `done` when the model is ready (the caller resumes `waiter` itself); otherwise `waiter` waits for the
    /// attempt in progress (`joined`), or for a new one the caller must start (`started`).
    func join(_ waiter: CheckedContinuation<Void, Never>) -> Join {
        state.withLock { state in
            if state.outcome == .ready && !state.running { return .done }
            state.waiters.append(waiter)
            if state.running { return .joined }
            state.running = true
            state.outcome = nil
            return .started
        }
    }

    /// Ends the attempt and hands back everyone waiting for it.
    func finish(_ outcome: EngineReadiness) -> [CheckedContinuation<Void, Never>] {
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
    let snapshot: DictionarySnapshot
    let bias: BiasGraph?
    var transcription = ChunkedTranscription.recording()
    var retained: RetainedAudio?
    var failure: SpeechFailure?

    init(snapshot: DictionarySnapshot, bias: BiasGraph?, retainsAudio: Bool) {
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
