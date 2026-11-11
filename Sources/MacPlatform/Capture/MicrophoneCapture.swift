@preconcurrency import AVFoundation
import DictationCore
import Synchronization

/// The microphone (ARCHITECTURE.md, section 6, "Audio capture"; the `AudioCapturing` port).
///
/// Every start and teardown runs on one serial queue, in the order asked, so a new capture never gets the
/// microphone before the previous one has let go of it, and the microphone is held only from `start` until the
/// capture's teardown has finished. A dedicated queue rather than an actor because `AVCaptureSession` starts and
/// stops with blocking calls that must not run on a shared executor.
///
/// Samples arrive as 16 kHz mono `Float` chunks stamped with `clock`'s time when each buffer arrived, a few
/// milliseconds after its last sample was heard.
public final class MicrophoneCapture: AudioCapturing {
    /// How long `start` waits, including any wait for the previous capture's teardown. It has to cover a
    /// Bluetooth headset switching profile.
    public static let startTimeout: TimeInterval = 3
    /// How long without a buffer before a capture reports `stalled`.
    public static let stallTimeout: TimeInterval = 2

    private let opener: any CaptureSourceOpening
    private let clock: any SessionClock
    private let lifecycle = DispatchQueue(label: "sorello.capture.lifecycle", qos: .userInitiated)

    /// The real microphone. `clock` stamps the chunks and times the start and stall limits.
    public convenience init(clock: any SessionClock = SystemSessionClock()) {
        self.init(opener: AVCaptureSource(), clock: clock)
    }

    init(opener: any CaptureSourceOpening, clock: any SessionClock) {
        self.opener = opener
        self.clock = clock
    }

    public func start(_ request: CaptureRequest) async throws -> any AudioCapture {
        let attempt = StartAttempt()
        let (opener, clock, lifecycle) = (opener, clock, lifecycle)
        lifecycle.async {
            guard attempt.begin() else { return }
            let capture = LiveCapture(clock: clock, lifecycle: lifecycle)
            do throws(CaptureFailure) {
                let source = try opener.open(request, sink: WeakSink(capture))
                capture.attach(source)
                if !attempt.succeed(capture) {
                    // Whoever started this gave up while the device was opening: let go of it before they hear so.
                    capture.tearDownNow()
                    attempt.released()
                }
            } catch {
                attempt.fail(error)
            }
        }
        attempt.setTimeout(Task {
            do { try await clock.sleep(for: Self.startTimeout) } catch { return }
            attempt.giveUp(CaptureFailure.startTimedOut)
        })
        return try await withTaskCancellationHandler {
            try await attempt.result()
        } onCancel: {
            attempt.giveUp(CancellationError())
        }
    }
}

/// One `start` call: its outcome, and whether its caller has given up (timeout or cancellation).
///
/// If the caller gives up while the start is still queued, it hears at once and the start never opens anything.
/// If it gives up while the device is opening, it hears only after the device has been released, so a thrown
/// `start` never leaves the microphone held.
private final class StartAttempt: Sendable {
    private enum Phase { case queued, opening, done }

    private struct State {
        var phase = Phase.queued
        var gaveUp: (any Error)?
        var outcome: Result<LiveCapture, any Error>?
        var waiter: CheckedContinuation<LiveCapture, any Error>?
        var timeout: Task<Void, Never>?
    }

    private let state = Mutex(State())

    func setTimeout(_ task: Task<Void, Never>) {
        let finished = state.withLock { state in
            if state.phase == .done { return true }
            state.timeout = task
            return false
        }
        if finished { task.cancel() }
    }

    func result() async throws -> LiveCapture {
        try await withCheckedThrowingContinuation { continuation in
            let outcome = state.withLock { state in
                if state.outcome == nil { state.waiter = continuation }
                defer { state.outcome = nil }
                return state.outcome
            }
            if let outcome { continuation.resume(with: outcome) }
        }
    }

    /// On the queue, before opening: false if the caller has already given up.
    func begin() -> Bool {
        state.withLock { state in
            // `giveUp` marks a queued attempt before it settles it, so both are checked here: an attempt whose
            // caller has given up never opens the device, even in the moment before it is settled.
            guard state.phase == .queued, state.gaveUp == nil else { return false }
            state.phase = .opening
            return true
        }
    }

    /// On the queue, once the device runs: false if the caller gave up meanwhile.
    func succeed(_ capture: LiveCapture) -> Bool {
        resolve(.success(capture), unlessGaveUp: true)
    }

    func fail(_ error: CaptureFailure) {
        let gaveUp = state.withLock { $0.gaveUp }
        resolve(.failure(gaveUp ?? error))
    }

    /// On the queue, after tearing down a capture whose caller gave up.
    func released() {
        let gaveUp = state.withLock { $0.gaveUp }
        resolve(.failure(gaveUp ?? CancellationError()))
    }

    func giveUp(_ error: any Error) {
        let resolveNow = state.withLock { state -> Bool in
            guard state.phase != .done, state.gaveUp == nil else { return false }
            state.gaveUp = error
            return state.phase == .queued
        }
        if resolveNow { resolve(.failure(error)) }
    }

    /// Settles the outcome once. With `unlessGaveUp`, a caller that has given up is not settled and the result is
    /// false.
    @discardableResult
    private func resolve(_ outcome: Result<LiveCapture, any Error>, unlessGaveUp: Bool = false) -> Bool {
        typealias Waiter = CheckedContinuation<LiveCapture, any Error>
        let settled = state.withLock { state -> (waiter: Waiter?, timeout: Task<Void, Never>?)? in
            guard state.phase != .done, !(unlessGaveUp && state.gaveUp != nil) else { return nil }
            state.phase = .done
            // Kept only until someone waits for it, so the attempt does not keep a capture alive.
            if state.waiter == nil { state.outcome = outcome }
            defer { state.waiter = nil; state.timeout = nil }
            return (state.waiter, state.timeout)
        }
        guard let settled else { return false }
        settled.timeout?.cancel()
        settled.waiter?.resume(with: outcome)
        return true
    }
}

/// What a source holds on to: the capture, weakly, so that a capture dropped without `stop` or `abort` is still
/// freed, and its `deinit` releases the device.
private final class WeakSink: CaptureSourceSink, @unchecked Sendable {
    // Safe: Swift's weak references are loaded and stored atomically, and `target` is set once, in `init`.
    private weak var target: LiveCapture?

    init(_ target: LiveCapture) { self.target = target }

    func received(_ buffer: AVAudioPCMBuffer) { target?.received(buffer) }
    func interrupted(_ reason: CaptureInterruption) { target?.interrupted(reason) }
    func failed() { target?.failed() }
}

/// One running capture: converts what the source delivers, reports stalls and trouble, and tears down on the
/// lifecycle queue.
final class LiveCapture: AudioCapture, CaptureSourceSink {
    let events: AsyncStream<CaptureEvent>

    private enum Phase {
        case running
        /// `events` is finished: after `stop` delivered the tail, or at once after `abort`.
        case finished
    }

    private struct State {
        var phase = Phase.running
        var conversion = AudioConversion()
        var source: (any CaptureSourceRunning)?
        var lastHeard: TimeInterval
        var stalled = false
        var troubled = false
        var watchdog: Task<Void, Never>?
    }

    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private let clock: any SessionClock
    private let lifecycle: DispatchQueue
    private let state: Mutex<State>

    init(clock: any SessionClock, lifecycle: DispatchQueue) {
        (events, continuation) = AsyncStream.makeStream(of: CaptureEvent.self, bufferingPolicy: .unbounded)
        self.clock = clock
        self.lifecycle = lifecycle
        state = Mutex(State(lastHeard: clock.now))
    }

    deinit {
        // Dropped without stop or abort: the microphone must still be let go of.
        let source = state.withLock { state -> (any CaptureSourceRunning)? in
            state.watchdog?.cancel()
            defer { state.source = nil }
            return state.source
        }
        continuation.finish()
        if let source { lifecycle.async { source.stop() } }
    }

    /// On the lifecycle queue, once the source runs.
    func attach(_ source: any CaptureSourceRunning) {
        let watchdog = Task { [weak self, clock] in
            var wait = MicrophoneCapture.stallTimeout
            while true {
                do { try await clock.sleep(for: wait) } catch { return }
                guard let self, let next = self.checkStall() else { return }
                wait = next
            }
        }
        state.withLock { state in
            state.source = source
            state.lastHeard = clock.now
            state.watchdog = watchdog
        }
    }

    // MARK: AudioCapture

    func stop() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            lifecycle.async {
                self.tearDown(flush: true)
                done.resume()
            }
        }
    }

    func abort() {
        finishEvents()
        lifecycle.async { self.tearDown(flush: false) }
    }

    /// On the lifecycle queue: abort and tear down before anything else runs there.
    func tearDownNow() {
        finishEvents()
        tearDown(flush: false)
    }

    // MARK: CaptureSourceSink

    func received(_ buffer: AVAudioPCMBuffer) {
        let now = clock.now
        state.withLock { state in
            guard state.phase == .running else { return }
            state.lastHeard = now
            do {
                let samples = try state.conversion.convert(buffer)
                if !samples.isEmpty { continuation.yield(.chunk(AudioChunk(samples: samples, time: now))) }
            } catch {
                report(.failed(.failed), in: &state)
            }
        }
    }

    func interrupted(_ reason: CaptureInterruption) {
        state.withLock { report(.interrupted(reason), in: &$0) }
    }

    func failed() {
        state.withLock { report(.failed(.failed), in: &$0) }
    }

    // MARK: Internals

    /// One report of trouble per capture: the first reason is the one that matters.
    private func report(_ event: CaptureEvent, in state: inout State) {
        guard state.phase == .running, !state.troubled else { return }
        state.troubled = true
        Diagnostics.record("capture.trouble")
        continuation.yield(event)
    }

    /// Reports `stalled` once if nothing has arrived for the stall timeout. Returns how long to wait before
    /// checking again, or nil when there is nothing more to watch.
    private func checkStall() -> TimeInterval? {
        let now = clock.now
        return state.withLock { state -> TimeInterval? in
            guard state.phase == .running, !state.stalled else { return nil }
            let quiet = now - state.lastHeard
            guard quiet >= MicrophoneCapture.stallTimeout else { return MicrophoneCapture.stallTimeout - quiet }
            state.stalled = true
            Diagnostics.record("capture.stalled")
            continuation.yield(.stalled)
            return nil
        }
    }

    private func finishEvents() {
        state.withLock { state in
            guard state.phase == .running else { return }
            state.phase = .finished
            continuation.finish()
        }
    }

    /// On the lifecycle queue. Releases the device; with `flush`, and unless `abort` came first, delivers the
    /// converter's tail and finishes `events`.
    private func tearDown(flush: Bool) {
        let source = state.withLock { state -> (any CaptureSourceRunning)? in
            state.watchdog?.cancel()
            state.watchdog = nil
            defer { state.source = nil }
            return state.source
        }
        source?.stop()
        state.withLock { state in
            guard state.phase == .running else { return }
            if flush, let tail = try? state.conversion.flush(), !tail.isEmpty {
                continuation.yield(.chunk(AudioChunk(samples: tail, time: state.lastHeard)))
            }
            state.phase = .finished
            continuation.finish()
        }
    }
}
