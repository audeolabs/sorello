import DictationCore
import Foundation
import Synchronization
import Testing

// Fakes for every port the runtime uses. Each records what was asked of it, and the ones whose answers take time
// let the test decide when, and how, they answer.

// MARK: - Clock

/// A clock that moves only when the test advances it.
final class ManualClock: SessionClock {
    private struct Sleeper {
        let id: UInt64
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: TimeInterval
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        var cancelledBeforeSleeping: Set<UInt64> = []
    }

    private let state: Mutex<State>

    init(now: TimeInterval = 1000) { state = Mutex(State(now: now)) }

    var now: TimeInterval { state.withLock { $0.now } }

    /// How many sleepers are waiting.
    var sleepers: Int { state.withLock { $0.sleepers.count } }

    func sleep(for seconds: TimeInterval) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { state in
                    if state.cancelledBeforeSleeping.remove(id) != nil { return true }
                    state.sleepers.append(Sleeper(id: id, deadline: state.now + seconds, continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelledBeforeSleeping.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has come, earliest first.
    func advance(by seconds: TimeInterval) {
        let due = state.withLock { state -> [Sleeper] in
            state.now += seconds
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }.sorted { $0.deadline < $1.deadline }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

// MARK: - Capture

/// Starts fake captures. By default a start succeeds at once; with `holdStarts` each start waits for the test.
final class FakeCapturing: AudioCapturing {
    private struct State {
        var holdStarts = false
        var requests: [CaptureRequest] = []
        var captures: [FakeCapture] = []
        var waiting: [CheckedContinuation<Result<FakeCapture, CaptureFailure>, Never>] = []
        var failNext: CaptureFailure?
    }

    private let state = Mutex(State())

    var holdStarts: Bool {
        get { state.withLock { $0.holdStarts } }
        set { state.withLock { $0.holdStarts = newValue } }
    }

    /// The next start throws this.
    func failNextStart(_ failure: CaptureFailure) { state.withLock { $0.failNext = failure } }

    var requests: [CaptureRequest] { state.withLock { $0.requests } }
    var captures: [FakeCapture] { state.withLock { $0.captures } }
    var waitingStarts: Int { state.withLock { $0.waiting.count } }

    func start(_ request: CaptureRequest) async throws -> any AudioCapture {
        let immediate = state.withLock { state -> Result<FakeCapture, CaptureFailure>? in
            state.requests.append(request)
            if let failure = state.failNext {
                state.failNext = nil
                return .failure(failure)
            }
            guard !state.holdStarts else { return nil }
            let capture = FakeCapture()
            state.captures.append(capture)
            return .success(capture)
        }
        let result: Result<FakeCapture, CaptureFailure>
        if let immediate {
            result = immediate
        } else {
            result = await withCheckedContinuation { continuation in
                state.withLock { $0.waiting.append(continuation) }
            }
        }
        return try result.get()
    }

    /// Answers the oldest waiting start: a live capture, or a failure. Like a real adapter that finished its work
    /// just as the caller was cancelled, it returns the capture even to a cancelled caller.
    @discardableResult
    func finishStart(failing failure: CaptureFailure? = nil) -> FakeCapture? {
        let (continuation, capture) = state.withLock { state -> (CheckedContinuation<Result<FakeCapture, CaptureFailure>, Never>?, FakeCapture?) in
            guard !state.waiting.isEmpty else { return (nil, nil) }
            let continuation = state.waiting.removeFirst()
            guard failure == nil else { return (continuation, nil) }
            let capture = FakeCapture()
            state.captures.append(capture)
            return (continuation, capture)
        }
        if let capture {
            continuation?.resume(returning: .success(capture))
        } else if let failure {
            continuation?.resume(returning: .failure(failure))
        }
        return capture
    }
}

/// One running fake capture. The test delivers chunks and reports; `stop` delivers the queued tail and finishes.
final class FakeCapture: AudioCapture {
    private struct State {
        var stops = 0
        var aborts = 0
        var finished = false
        var tail: [AudioChunk] = []
        var stopFinishes = true
    }

    let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private let state = Mutex(State())

    init() {
        (events, continuation) = AsyncStream<CaptureEvent>.makeStream()
    }

    var stops: Int { state.withLock { $0.stops } }
    var aborts: Int { state.withLock { $0.aborts } }
    /// The microphone was let go: by a stop that finished, or by an abort.
    var isReleased: Bool { state.withLock { $0.finished } }

    /// Chunks `stop` delivers before it finishes, like a converter's tail.
    func queueTail(_ chunks: [AudioChunk]) { state.withLock { $0.tail = chunks } }

    /// When false, `stop` hangs on to the microphone and never finishes, so only `abort` ends the capture.
    func stopFinishes(_ finishes: Bool) { state.withLock { $0.stopFinishes = finishes } }

    func deliver(_ event: CaptureEvent) {
        if !state.withLock({ $0.finished }) { continuation.yield(event) }
    }

    /// Delivers `seconds` of synthetic audio as one chunk.
    func deliver(seconds: TimeInterval, at time: TimeInterval, value: Float = 0.1) {
        deliver(.chunk(AudioChunk(samples: samples(seconds, value), time: time)))
    }

    func stop() async {
        let tail = state.withLock { state -> [AudioChunk]? in
            state.stops += 1
            guard !state.finished, state.stopFinishes else { return nil }
            state.finished = true
            return state.tail
        }
        guard let tail else { return }
        for chunk in tail { continuation.yield(.chunk(chunk)) }
        continuation.finish()
    }

    func abort() {
        state.withLock { state in
            state.aborts += 1
            state.finished = true
        }
        continuation.finish()
    }
}

/// `seconds` of a constant synthetic signal at 16 kHz.
func samples(_ seconds: TimeInterval, _ value: Float = 0.1) -> [Float] {
    Array(repeating: value, count: Int((seconds * AudioFormat.sampleRate).rounded()))
}

// MARK: - Speech

/// A speech engine whose streams answer when the test says, or at once with `autoResult`.
final class FakeSpeech: SpeechTranscribing {
    private struct State {
        var prepares = 0
        var streams: [FakeStream] = []
        var options: [SpeechStreamOptions] = []
        var autoResult: Result<SpeechResult, SpeechFailure>?
    }

    private let state = Mutex(State())
    private let readinessStream: AsyncStream<EngineReadiness>
    private let readinessContinuation: AsyncStream<EngineReadiness>.Continuation

    init(autoResult: Result<SpeechResult, SpeechFailure>? = nil) {
        (readinessStream, readinessContinuation) = AsyncStream<EngineReadiness>.makeStream()
        state.withLock { $0.autoResult = autoResult }
    }

    var prepares: Int { state.withLock { $0.prepares } }
    var streams: [FakeStream] { state.withLock { $0.streams } }
    var options: [SpeechStreamOptions] { state.withLock { $0.options } }

    func report(_ readiness: EngineReadiness) { readinessContinuation.yield(readiness) }

    /// What streams opened from now on answer at once.
    func setAutoResult(_ result: Result<SpeechResult, SpeechFailure>?) { state.withLock { $0.autoResult = result } }

    func prepare() async { state.withLock { $0.prepares += 1 } }

    func readiness() -> AsyncStream<EngineReadiness> { readinessStream }

    func openStream(_ options: SpeechStreamOptions) -> any SpeechStreaming {
        state.withLock { state in
            let stream = FakeStream(result: state.autoResult)
            state.streams.append(stream)
            state.options.append(options)
            return stream
        }
    }
}

final class FakeStream: SpeechStreaming {
    private struct State {
        var appended: [Float] = []
        var finishes = 0
        var cancels = 0
        var result: Result<SpeechResult, SpeechFailure>?
        var waiting: CheckedContinuation<Result<SpeechResult, SpeechFailure>, Never>?
    }

    private let state: Mutex<State>

    init(result: Result<SpeechResult, SpeechFailure>?) { state = Mutex(State(result: result)) }

    var appended: [Float] { state.withLock { $0.appended } }
    var finishes: Int { state.withLock { $0.finishes } }
    var isCancelled: Bool { state.withLock { $0.cancels > 0 } }
    var isWaiting: Bool { state.withLock { $0.waiting != nil } }

    func append(_ samples: [Float]) {
        state.withLock { state in
            if state.finishes == 0 && state.cancels == 0 { state.appended += samples }
        }
    }

    func finish() async throws -> SpeechResult {
        let result = await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Result<SpeechResult, SpeechFailure>? in
                state.finishes += 1
                if state.cancels > 0 { return .failure(.cancelled) }
                if let result = state.result { return result }
                state.waiting = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        return try result.get()
    }

    /// Answers a `finish` that is waiting, or the next one.
    func complete(with result: Result<SpeechResult, SpeechFailure>) {
        let waiting = state.withLock { state in
            state.result = result
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume(returning: result)
    }

    func complete(_ text: String) { complete(with: .success(SpeechResult(text: text))) }

    func cancel() {
        let waiting = state.withLock { state in
            state.cancels += 1
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume(returning: .failure(.cancelled))
    }
}

// MARK: - Text

/// Text rules that are easy to recognise in a result: they prefix the transcript with a label and report the
/// context they were given.
struct LabelRules: TranscriptProcessing {
    var label: String

    func process(_ transcript: String, style: DictationStyle, context: InsertionContext?) -> ProcessedDictation {
        let pressEnter = transcript.hasSuffix("press enter")
        let body = pressEnter ? String(transcript.dropLast("press enter".count)).trimmingCharacters(in: .whitespaces)
                              : transcript
        let tag = style == .prompt ? "[prompt] " : ""
        let around = context.map { " (after \($0.before ?? "?"))" } ?? ""
        return ProcessedDictation(heard: transcript, text: body.isEmpty ? "" : "\(tag)\(label): \(body)\(around)",
                                  pressEnter: pressEnter, addedPromptTag: style == .prompt)
    }
}

/// An inserter that records each transaction. Its destination and outcome can be set, and with `holdTransactions`
/// each transaction waits for the test before it composes.
final class FakeInserter: TextInserting {
    struct Transaction: Equatable {
        var restoreClipboard: Bool
        var composed: ComposedInsertion
    }

    private struct State {
        var destination: InsertionDestination = .cursor(context: InsertionContext(before: "So ", after: nil),
                                                        field: DestinationField("field-token"))
        var outcome: InsertionOutcome?
        var transactions: [Transaction] = []
        var holdTransactions = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var transactions: [Transaction] { state.withLock { $0.transactions } }
    var waiting: Int { state.withLock { $0.waiting.count } }

    func setDestination(_ destination: InsertionDestination) { state.withLock { $0.destination = destination } }
    /// Overrides the outcome; by default it follows what was composed.
    func setOutcome(_ outcome: InsertionOutcome?) { state.withLock { $0.outcome = outcome } }

    var holdTransactions: Bool {
        get { state.withLock { $0.holdTransactions } }
        set { state.withLock { $0.holdTransactions = newValue } }
    }

    func releaseTransaction() {
        let next = state.withLock { state in state.waiting.isEmpty ? nil : state.waiting.removeFirst() }
        next?.resume()
    }

    func insert(restoreClipboard: Bool,
                compose: @escaping @Sendable (InsertionDestination) async -> ComposedInsertion) async
        -> InsertionOutcome {
        if holdTransactions {
            await withCheckedContinuation { continuation in state.withLock { $0.waiting.append(continuation) } }
        }
        let destination = state.withLock { $0.destination }
        let composed = await compose(destination)
        return state.withLock { state in
            state.transactions.append(Transaction(restoreClipboard: restoreClipboard, composed: composed))
            if let outcome = state.outcome { return outcome }
            if composed.text.isEmpty && !composed.pressEnter { return .nothingToInsert }
            if case .clipboard(let reason) = destination { return .leftOnClipboard(reason) }
            return .inserted
        }
    }
}

// MARK: - Permission, the app in front, the Run Log, levels

final class FakeMicrophone: MicrophoneAuthorizing {
    private struct State {
        var access: MicrophoneAccess
        var requests = 0
        var waiting: CheckedContinuation<MicrophoneAccess, Never>?
    }

    private let state: Mutex<State>

    init(_ access: MicrophoneAccess = .granted) { state = Mutex(State(access: access)) }

    var requests: Int { state.withLock { $0.requests } }
    var isAsking: Bool { state.withLock { $0.waiting != nil } }

    func set(_ access: MicrophoneAccess) { state.withLock { $0.access = access } }

    func current() -> MicrophoneAccess { state.withLock { $0.access } }

    /// Shows the "prompt": waits until the test answers.
    func request() async -> MicrophoneAccess {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                state.requests += 1
                state.waiting = continuation
            }
        }
    }

    func answer(_ access: MicrophoneAccess) {
        let waiting = state.withLock { state in
            state.access = access
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume(returning: access)
    }
}

final class FakeFrontmostApp: FrontmostAppReading {
    private let app = Mutex<AppIdentity?>(AppIdentity(bundleID: "com.example.notes", name: "Notes"))

    func set(_ app: AppIdentity?) { self.app.withLock { $0 = app } }

    @MainActor func frontmostApp() -> AppIdentity? { app.withLock { $0 } }
}

final class FakeHistory: HistoryRecording {
    private let drafts = Mutex<[HistoryDraft]>([])

    var recorded: [HistoryDraft] { drafts.withLock { $0 } }

    func record(_ draft: HistoryDraft) async { drafts.withLock { $0.append(draft) } }
}

final class FakeLevels: LevelSink {
    private struct State {
        var heard: [DictationID: Int] = [:]
        var ended: [DictationID] = []
    }

    private let state = Mutex(State())

    /// Samples heard per dictation.
    var heard: [DictationID: Int] { state.withLock { $0.heard } }
    var ended: [DictationID] { state.withLock { $0.ended } }

    func heard(_ samples: [Float], at time: TimeInterval, dictation: DictationID) {
        state.withLock { $0.heard[dictation, default: 0] += samples.count }
    }

    func captureEnded(dictation: DictationID) { state.withLock { $0.ended.append(dictation) } }
}

// MARK: - Waiting

/// Lets the runtime's tasks run until `condition` holds, or records an issue after two seconds of real time.
@MainActor
func eventually(_ what: String = "condition", sourceLocation: SourceLocation = #_sourceLocation,
                _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        if Date() > deadline {
            Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
            return
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// Lets every task that can make progress do so, for checks that something did not happen.
@MainActor
func settle() async {
    for _ in 0..<50 {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}
