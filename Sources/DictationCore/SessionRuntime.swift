import Foundation
import Observation

/// The adapters the session works through (ARCHITECTURE.md, section 4). The app builds each once and hands them over
/// together.
public struct SessionPorts: Sendable {
    public var capture: any AudioCapturing
    public var speech: any SpeechTranscribing
    public var inserter: any TextInserting
    public var microphone: any MicrophoneAuthorizing
    public var frontmostApp: any FrontmostAppReading
    public var history: any HistoryRecording
    public var levels: any LevelSink
    public var clock: any SessionClock

    public init(capture: any AudioCapturing, speech: any SpeechTranscribing, inserter: any TextInserting,
                microphone: any MicrophoneAuthorizing, frontmostApp: any FrontmostAppReading,
                history: any HistoryRecording, levels: any LevelSink, clock: any SessionClock) {
        self.capture = capture
        self.speech = speech
        self.inserter = inserter
        self.microphone = microphone
        self.frontmostApp = frontmostApp
        self.history = history
        self.levels = levels
        self.clock = clock
    }
}

/// Called during an insertion, once the text is composed and before it is pasted: the dictation, the text rules'
/// result and where the text is going. The app uses it to set up the correction watch from the destination's
/// `DestinationField`, which the session passes along unopened. It runs off the main actor, inside the inserter's
/// transaction, so it should be quick.
public typealias InsertionHook = @Sendable (DictationID, ProcessedDictation, InsertionDestination) async -> Void

/// Owns the session's state and does what `Session.reduce` decides (ARCHITECTURE.md, sections 3 and 4).
///
/// Every change to dictation state goes through `reduce`; this class only turns what the ports report into events
/// and performs the effects that come back. Cleanup is its own business and never depends on whether an event was
/// stale: each dictation has one task, which holds the capture and the stream, and every way out of that task
/// releases what it holds.
@MainActor
@Observable
public final class SessionRuntime: TriggerHandling {
    /// All dictation state. Observable, so the app can follow it.
    public private(set) var state = SessionState()

    /// What the pill shows now.
    public var pill: PillContent { PillContent(state) }

    /// Called during each dictation's insertion, after composition and before the paste. Not called for Paste
    /// Again.
    @ObservationIgnored public var willInsert: InsertionHook?

    /// Called once for every dictation that leaves the session, however it ends.
    @ObservationIgnored public var onCompletion: (@MainActor (DictationCompletion) -> Void)?

    @ObservationIgnored private let ports: SessionPorts
    @ObservationIgnored private let settings: @MainActor () -> SessionSettings
    @ObservationIgnored private let textRules: @MainActor () -> any TranscriptProcessing
    @ObservationIgnored private let date: @Sendable () -> Date
    @ObservationIgnored private var dictations: [DictationID: DictationWork] = [:]
    @ObservationIgnored private var timers: [TimerID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pending: [SessionEffect] = []
    @ObservationIgnored private var performing = false
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var readinessWatch: Task<Void, Never>?

    /// - Parameters:
    ///   - settings: The current settings; read for every event.
    ///   - textRules: The current text rules; read once when each dictation starts, and kept for it.
    ///   - date: The wall-clock date for Run Log entries.
    public init(ports: SessionPorts, settings: @escaping @MainActor () -> SessionSettings,
                textRules: @escaping @MainActor () -> any TranscriptProcessing,
                date: @escaping @Sendable () -> Date = { Date() }) {
        self.ports = ports
        self.settings = settings
        self.textRules = textRules
        self.date = date
    }

    isolated deinit {
        readinessWatch?.cancel()
        for timer in timers.values { timer.cancel() }
        for dictation in dictations.values { dictation.release() }
    }

    // MARK: Inputs

    /// Reads the microphone permission, follows the engine's readiness and starts preparing the model. Call once,
    /// at launch; later calls do nothing.
    public func start() {
        guard readinessWatch == nil else { return }
        send(.microphoneAccess(ports.microphone.current()))
        let speech = ports.speech
        readinessWatch = Task { [weak self] in
            for await readiness in speech.readiness() {
                self?.send(.engine(readiness))
            }
        }
        Task { await speech.prepare() }
    }

    /// Decides what the trigger does and returns at once; the work it sets in motion is done after this returns,
    /// because this is called from inside the keyboard event tap.
    @discardableResult
    public func handle(_ trigger: TriggerEvent, at time: TimeInterval) -> Bool {
        let outcome = Session.handle(&state, trigger, at: time, settings: settings())
        pending += outcome.effects
        if !pending.isEmpty && !flushScheduled {
            flushScheduled = true
            Task { [weak self] in self?.flush() }
        }
        return outcome.acted
    }

    /// Forgets the text Paste Again would insert, for Clear in the Run Log.
    public func forgetLast() {
        send(.forgetLast)
    }

    /// Tries to prepare the model again after a failure.
    public func retryPreparation() {
        let speech = ports.speech
        Task { await speech.prepare() }
    }

    /// Reads the microphone permission again, for when the user may have changed it in System Settings.
    public func refreshMicrophoneAccess() {
        send(.microphoneAccess(ports.microphone.current()))
    }

    // MARK: Events and effects

    fileprivate func send(_ event: SessionEvent) {
        pending += Session.reduce(&state, event, settings: settings())
        flush()
    }

    /// Performs the pending effects in order. Re-entrant calls (an effect's hook sending an event) only add to the
    /// queue, so effects never run out of order.
    private func flush() {
        flushScheduled = false
        guard !performing else { return }
        performing = true
        defer { performing = false }
        while !pending.isEmpty {
            perform(pending.removeFirst())
        }
    }

    private func perform(_ effect: SessionEffect) {
        switch effect {
        case .requestMicrophoneAccess:
            let microphone = ports.microphone
            Task { [weak self] in
                let access = await microphone.request()
                self?.send(.microphoneAccess(access))
            }
        case .startCapture(let id, let request):
            startCapture(id, request)
        case .openStream(let id, let retainForCorrection):
            guard let dictation = dictations[id] else { return }
            dictation.stream = ports.speech.openStream(
                SpeechStreamOptions(appBundleID: dictation.app?.bundleID, retainForCorrection: retainForCorrection))
        case .stopCapture(let id):
            guard let capture = dictations[id]?.capture else { return }
            Task { await capture.stop() }
        case .abortCapture(let id):
            dictations[id]?.capture?.abort()
        case .finishStream(let id):
            dictations[id]?.finishRequest.yield()
        case .discard(let id):
            guard let dictation = dictations.removeValue(forKey: id) else { return }
            dictation.release()
            ports.levels.captureEnded(dictation: id)
        case .insert(let request):
            insert(request)
        case .reinsert(let replay, let text, let restoreClipboard):
            reinsert(replay, text: text, restoreClipboard: restoreClipboard)
        case .setTimer(let timer, let delay):
            arm(timer, after: delay)
        case .cancelTimer(let timer):
            timers.removeValue(forKey: timer)?.cancel()
        case .record(let entry):
            let draft = HistoryDraft(date: date(), heard: entry.heard, text: entry.text, outcome: entry.outcome,
                                     samples: dictations[entry.dictation]?.recording ?? [])
            let history = ports.history
            Task { await history.record(draft) }
        case .complete(let completion):
            // The dictation's task has ended or been cancelled by now; only the bookkeeping is left.
            dictations[completion.id] = nil
            onCompletion?(completion)
        }
    }

    // MARK: The dictation's task

    /// Reads the app in front and the text rules, which stay with the dictation, and starts its task.
    private func startCapture(_ id: DictationID, _ request: CaptureRequest) {
        let (finishRequests, finishRequest) = AsyncStream<Void>.makeStream()
        let dictation = DictationWork(app: ports.frontmostApp.frontmostApp(), textRules: textRules(),
                                      finishRequest: finishRequest)
        dictations[id] = dictation
        let capturing = ports.capture
        let levels = ports.levels
        let runtime = RuntimeLink(self)
        dictation.task = Task {
            await SessionRuntime.run(id, request, capturing: capturing, levels: levels,
                                     finishRequests: finishRequests, runtime: runtime)
        }
    }

    /// One dictation from the microphone to its transcript, off the main actor. It is the only reader of the
    /// capture's events. Cancelling it (a discard) ends it at whichever step it is on, and each step releases the
    /// capture and stream it holds.
    @concurrent
    private nonisolated static func run(_ id: DictationID, _ request: CaptureRequest,
                                        capturing: any AudioCapturing, levels: any LevelSink,
                                        finishRequests: AsyncStream<Void>, runtime: RuntimeLink) async {
        let capture: any AudioCapture
        do {
            capture = try await capturing.start(request)
        } catch {
            await runtime.send(.capture(id, .failed(error as? CaptureFailure ?? .failed)))
            return
        }
        // A capture handed over after its dictation was discarded is aborted at once.
        guard !Task.isCancelled, let stream = await runtime.attach(capture, to: id) else {
            capture.abort()
            return
        }

        var recording: [Float] = []
        for await event in capture.events {
            switch event {
            case .chunk(let chunk):
                stream.append(chunk.samples)
                levels.heard(chunk.samples, at: chunk.time, dictation: id)
                recording.append(contentsOf: chunk.samples)
            case .stalled:
                await runtime.send(.capture(id, .stalled))
            case .interrupted(let reason):
                await runtime.send(.capture(id, .interrupted(reason)))
            case .failed(let failure):
                await runtime.send(.capture(id, .failed(failure)))
            }
        }
        levels.captureEnded(dictation: id)
        guard !Task.isCancelled else {
            capture.abort()
            stream.cancel()
            return
        }
        // Every delivered chunk has been appended: now, and only now, the capture has ended.
        await runtime.captureEnded(id, recording: recording)

        var requests = finishRequests.makeAsyncIterator()
        guard await requests.next() != nil, !Task.isCancelled else {
            stream.cancel()
            return
        }
        let result: Result<SpeechResult, SpeechFailure>
        do {
            result = .success(try await stream.finish())
        } catch {
            result = .failure(error as? SpeechFailure ?? .failed)
        }
        await runtime.send(.transcript(id, result))
    }

    /// Hands the capture to the dictation and reports that it started. Returns the stream its audio goes to, or nil
    /// if the dictation is gone, in which case the caller aborts the capture.
    fileprivate func attach(_ capture: any AudioCapture, to id: DictationID) -> (any SpeechStreaming)? {
        guard let dictation = dictations[id], let stream = dictation.stream else { return nil }
        dictation.capture = capture
        send(.capture(id, .started))
        return stream
    }

    fileprivate func captureEnded(_ id: DictationID, recording: [Float]) {
        dictations[id]?.recording = recording
        send(.capture(id, .ended(CaptureSummary(sampleCount: recording.count))))
    }

    // MARK: Insertion

    /// Runs the transaction. The text rules run inside `compose`, with the context the inserter read once the text
    /// before has landed, and the hook sees the result before anything is pasted.
    private func insert(_ request: InsertionRequest) {
        let rules = dictations[request.id]?.textRules ?? textRules()
        let hook = willInsert
        let inserter = ports.inserter
        Task { [weak self] in
            let composition = Composition()
            let outcome = await inserter.insert(restoreClipboard: request.restoreClipboard) { destination in
                let context: InsertionContext?
                if case .cursor(let read, _) = destination { context = read } else { context = nil }
                let processed = rules.process(request.speech.text, style: request.style, context: context)
                await composition.keep(processed)
                await hook?(request.id, processed, destination)
                return ComposedInsertion(text: processed.text, pressEnter: processed.pressEnter)
            }
            let processed = await composition.processed
            self?.send(.insertion(request.id, InsertionReport(outcome: outcome, processed: processed)))
        }
    }

    /// Paste Again: the remembered text, verbatim, without Return and without the hook.
    private func reinsert(_ replay: ReplayID, text: String, restoreClipboard: Bool) {
        let inserter = ports.inserter
        Task { [weak self] in
            let outcome = await inserter.insert(restoreClipboard: restoreClipboard) { _ in
                ComposedInsertion(text: text, pressEnter: false)
            }
            self?.send(.reinsertion(replay, outcome))
        }
    }

    // MARK: Timers

    private func arm(_ timer: TimerID, after delay: TimeInterval) {
        let clock = ports.clock
        timers[timer] = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.timers[timer] = nil
            self.send(.timer(timer))
        }
    }
}

/// How a dictation's task reaches the runtime without keeping it alive. A runtime that goes away cancels its
/// dictations' tasks as it goes; until they notice, whatever they report goes nowhere.
@MainActor
private final class RuntimeLink {
    private weak var runtime: SessionRuntime?

    init(_ runtime: SessionRuntime) { self.runtime = runtime }

    func send(_ event: SessionEvent) { runtime?.send(event) }

    /// Nil when the runtime is gone, so the caller aborts the capture.
    func attach(_ capture: any AudioCapture, to id: DictationID) -> (any SpeechStreaming)? {
        runtime?.attach(capture, to: id)
    }

    func captureEnded(_ id: DictationID, recording: [Float]) { runtime?.captureEnded(id, recording: recording) }
}

/// What the runtime holds for one dictation while it exists: what was read when it started, its task, and the
/// resources that task uses.
@MainActor
private final class DictationWork {
    let app: AppIdentity?
    let textRules: any TranscriptProcessing
    /// Tells the task to finish the stream, once the capture has ended.
    let finishRequest: AsyncStream<Void>.Continuation
    var task: Task<Void, Never>?
    var capture: (any AudioCapture)?
    var stream: (any SpeechStreaming)?
    /// The recording kept for the Run Log, handed over when the capture ends.
    var recording: [Float] = []

    init(app: AppIdentity?, textRules: any TranscriptProcessing, finishRequest: AsyncStream<Void>.Continuation) {
        self.app = app
        self.textRules = textRules
        self.finishRequest = finishRequest
    }

    /// Throws the dictation's work away: the task stops, the microphone and the stream are let go.
    func release() {
        task?.cancel()
        capture?.abort()
        stream?.cancel()
        finishRequest.finish()
        recording = []
    }
}

/// Carries what composition produced out of the inserter's transaction.
private actor Composition {
    private(set) var processed: ProcessedDictation?

    func keep(_ processed: ProcessedDictation) { self.processed = processed }
}
