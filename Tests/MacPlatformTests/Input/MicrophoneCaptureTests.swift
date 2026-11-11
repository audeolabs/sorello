@preconcurrency import AVFoundation
import DictationCore
@testable import MacPlatform
import Synchronization
import Testing

/// A gate a fake blocks on, on the capture's queue, until the test opens it.
private final class Gate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let entered = Mutex(false)

    func pass() {
        entered.withLock { $0 = true }
        semaphore.wait()
    }

    func open() { semaphore.signal() }

    var isWaiting: Bool { entered.withLock { $0 } }

    func waitUntilEntered() async {
        for _ in 0..<5_000 where !isWaiting { try? await Task.sleep(for: .milliseconds(1)) }
    }
}

/// What happened to the fake microphone, in order.
private final class Log: Sendable {
    private let entries = Mutex<[String]>([])
    func add(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
}

private final class FakeSource: CaptureSourceRunning {
    let name: String
    let sink: any CaptureSourceSink
    let log: Log
    let stopGate: Gate?

    init(name: String, sink: any CaptureSourceSink, log: Log, stopGate: Gate?) {
        self.name = name
        self.sink = sink
        self.log = log
        self.stopGate = stopGate
    }

    func stop() {
        stopGate?.pass()
        log.add("stop \(name)")
    }
}

private final class FakeOpener: CaptureSourceOpening {
    struct Plan: Sendable {
        var error: CaptureFailure?
        var openGate: Gate?
        var stopGate: Gate?
    }

    let log = Log()
    private let plans = Mutex<[Plan]>([])
    private let opened = Mutex<[FakeSource]>([])

    func plan(_ plan: Plan) { plans.withLock { $0.append(plan) } }

    var sources: [FakeSource] { opened.withLock { $0 } }

    func open(_ request: CaptureRequest, sink: any CaptureSourceSink) throws(CaptureFailure) -> any CaptureSourceRunning {
        let plan = plans.withLock { $0.isEmpty ? Plan() : $0.removeFirst() }
        let name = "\(request.deviceID ?? "default")#\(sources.count + 1)"
        log.add("open \(name)")
        plan.openGate?.pass()
        if let error = plan.error { throw error }
        let source = FakeSource(name: name, sink: sink, log: log, stopGate: plan.stopGate)
        opened.withLock { $0.append(source) }
        return source
    }
}

/// Reads a capture's events from a task of its own, as the session's consumer does.
private final class Reader: Sendable {
    private final class Store: Sendable {
        let events = Mutex<[CaptureEvent]>([])
        let ended = Mutex(false)
    }

    private let store = Store()
    private let task: Task<Void, Never>

    init(_ capture: any AudioCapture) {
        let store = store
        task = Task {
            for await event in capture.events { store.events.withLock { $0.append(event) } }
            store.ended.withLock { $0 = true }
        }
    }

    var received: [CaptureEvent] { store.events.withLock { $0 } }
    var samples: [Float] {
        received.flatMap { event -> [Float] in
            if case .chunk(let chunk) = event { chunk.samples } else { [] }
        }
    }
    var chunkTimes: [TimeInterval] {
        received.compactMap { if case .chunk(let chunk) = $0 { chunk.time } else { nil } }
    }
    var others: [CaptureEvent] {
        received.filter { if case .chunk = $0 { false } else { true } }
    }
    var hasEnded: Bool { store.ended.withLock { $0 } }

    func waitForEnd() async { await task.value }

    func waitFor(_ condition: @Sendable (Reader) -> Bool) async {
        for _ in 0..<5_000 where !condition(self) { try? await Task.sleep(for: .milliseconds(1)) }
    }
}

private func makeCapture() -> (MicrophoneCapture, FakeOpener, TestClock) {
    let opener = FakeOpener()
    let clock = TestClock()
    return (MicrophoneCapture(opener: opener, clock: clock), opener, clock)
}

@Suite("Microphone capture")
struct MicrophoneCaptureTests {
    @Test("Buffers become 16 kHz chunks stamped on the clock, and stop delivers the tail and finishes")
    func chunksAndStop() async throws {
        let (microphone, opener, clock) = makeCapture()
        let capture = try await microphone.start(CaptureRequest())
        let reader = Reader(capture)
        let source = try #require(opener.sources.first)
        for (index, buffer) in Tone.buffers(rate: 48_000, channels: 2, seconds: 1).enumerated() {
            if index == 50 { clock.advance(by: 0.5) }
            source.sink.received(buffer)
        }
        await capture.stop()
        await reader.waitForEnd()
        #expect(abs(reader.samples.count - 16_000) <= 2)
        #expect(reader.chunkTimes.first == 1_000)
        #expect(reader.chunkTimes.last == 1_000.5)
        #expect(reader.others == [])
        #expect(opener.log.all == ["open default#1", "stop default#1"])
    }

    @Test("stop is safe to call twice; the device is released once")
    func stopTwice() async throws {
        let (microphone, opener, _) = makeCapture()
        let capture = try await microphone.start(CaptureRequest(deviceID: "usb"))
        await capture.stop()
        await capture.stop()
        #expect(opener.log.all == ["open usb#1", "stop usb#1"])
    }

    @Test("abort finishes events at once: chunks already delivered stay readable, later ones are dropped")
    func abort() async throws {
        let (microphone, opener, _) = makeCapture()
        let capture = try await microphone.start(CaptureRequest())
        let source = try #require(opener.sources.first)
        source.sink.received(Tone.buffer(rate: 16_000, frames: 1_600))
        capture.abort()
        source.sink.received(Tone.buffer(rate: 16_000, frames: 1_600))
        let reader = Reader(capture)
        await reader.waitForEnd()
        #expect(reader.samples.count == 1_600)
        await capture.stop()
        #expect(opener.log.all == ["open default#1", "stop default#1"], "stop after abort does nothing more")
    }

    @Test("abort wins over a stop in progress: no tail, and events finish before the device is released")
    func abortDuringStop() async throws {
        let (microphone, opener, _) = makeCapture()
        let stopGate = Gate()
        opener.plan(.init(stopGate: stopGate))
        let capture = try await microphone.start(CaptureRequest())
        let reader = Reader(capture)
        let source = try #require(opener.sources.first)
        source.sink.received(Tone.buffer(rate: 48_000, frames: 4_800))
        let stopping = Task { await capture.stop() }
        await stopGate.waitUntilEntered()
        capture.abort()
        await reader.waitForEnd()
        let delivered = reader.samples.count
        stopGate.open()
        await stopping.value
        #expect(reader.samples.count == delivered, "the converter's tail is discarded")
        #expect(opener.log.all == ["open default#1", "stop default#1"])
    }

    @Test("A capture that hears nothing for 2 s reports stalled once, and keeps running")
    func stall() async throws {
        let (microphone, opener, clock) = makeCapture()
        let capture = try await microphone.start(CaptureRequest())
        let reader = Reader(capture)
        let source = try #require(opener.sources.first)
        await clock.waitForSleepers()
        clock.advance(by: 1.5)
        source.sink.received(Tone.buffer(rate: 16_000, frames: 160))
        await clock.waitForSleepers()
        clock.advance(by: 1.5)
        await reader.waitFor { $0.received.count >= 1 }
        #expect(reader.others == [], "a buffer 1.5 s in resets the wait")
        await clock.waitForSleepers()
        clock.advance(by: 0.5)
        await reader.waitFor { !$0.others.isEmpty }
        #expect(reader.others == [.stalled])
        clock.advance(by: 10)
        source.sink.received(Tone.buffer(rate: 16_000, frames: 160))
        await capture.stop()
        await reader.waitForEnd()
        #expect(reader.others == [.stalled])
        #expect(reader.samples.count == 320)
    }

    @Test("A removed device or another error is reported once; the capture keeps what it has until stopped")
    func trouble() async throws {
        let (microphone, opener, _) = makeCapture()
        let capture = try await microphone.start(CaptureRequest())
        let reader = Reader(capture)
        let source = try #require(opener.sources.first)
        source.sink.received(Tone.buffer(rate: 16_000, frames: 160))
        source.sink.interrupted(.deviceRemoved)
        source.sink.failed()
        source.sink.interrupted(.sessionInterrupted)
        await capture.stop()
        await reader.waitForEnd()
        #expect(reader.others == [.interrupted(.deviceRemoved)])
        #expect(reader.samples.count == 160)
    }

    @Test("Failures to open are thrown", arguments: [CaptureFailure.permissionDenied, .noInputDevice,
                                                     .deviceUnavailable])
    func openFailure(failure: CaptureFailure) async {
        let (microphone, opener, _) = makeCapture()
        opener.plan(.init(error: failure))
        await #expect(throws: failure) { try await microphone.start(CaptureRequest()) }
    }

    @Test("Starts and teardowns run in the order asked: a new start waits for the last teardown")
    func order() async throws {
        let (microphone, opener, _) = makeCapture()
        let stopGate = Gate()
        opener.plan(.init(stopGate: stopGate))
        let first = try await microphone.start(CaptureRequest())
        first.abort()
        let second = Task { try await microphone.start(CaptureRequest()) }
        await stopGate.waitUntilEntered()
        try await Task.sleep(for: .milliseconds(20))
        #expect(opener.log.all == ["open default#1"], "the second start is still waiting")
        stopGate.open()
        let capture = try await second.value
        #expect(opener.log.all == ["open default#1", "stop default#1", "open default#2"])
        await capture.stop()
    }

    @Test("A start still queued after 3 s throws startTimedOut at once, and never opens the device")
    func timeoutWhileQueued() async throws {
        let (microphone, opener, clock) = makeCapture()
        let stopGate = Gate()
        opener.plan(.init(stopGate: stopGate))
        let first = try await microphone.start(CaptureRequest())
        first.abort()
        await stopGate.waitUntilEntered()
        let second = Task { try await microphone.start(CaptureRequest()) }
        await clock.waitForSleepers()
        clock.advance(by: MicrophoneCapture.startTimeout)
        await #expect(throws: CaptureFailure.startTimedOut) { try await second.value }
        stopGate.open()
        let third = try await microphone.start(CaptureRequest())
        #expect(opener.log.all == ["open default#1", "stop default#1", "open default#2"])
        await third.stop()
    }

    @Test("A start that times out while opening throws only after the device is released")
    func timeoutWhileOpening() async throws {
        let (microphone, opener, clock) = makeCapture()
        let openGate = Gate()
        opener.plan(.init(openGate: openGate))
        let start = Task { try await microphone.start(CaptureRequest()) }
        await openGate.waitUntilEntered()
        await clock.waitForSleepers()
        clock.advance(by: MicrophoneCapture.startTimeout)
        try await Task.sleep(for: .milliseconds(20))
        #expect(opener.log.all == ["open default#1"])
        openGate.open()
        await #expect(throws: CaptureFailure.startTimedOut) { try await start.value }
        #expect(opener.log.all == ["open default#1", "stop default#1"])
    }

    @Test("A cancelled start throws after releasing the device")
    func cancelWhileOpening() async throws {
        let (microphone, opener, _) = makeCapture()
        let openGate = Gate()
        opener.plan(.init(openGate: openGate))
        let start = Task { try await microphone.start(CaptureRequest()) }
        await openGate.waitUntilEntered()
        start.cancel()
        openGate.open()
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(opener.log.all == ["open default#1", "stop default#1"])
    }

    @Test("A start cancelled before it ran never opens the device")
    func cancelWhileQueued() async throws {
        let (microphone, opener, _) = makeCapture()
        let stopGate = Gate()
        opener.plan(.init(stopGate: stopGate))
        let first = try await microphone.start(CaptureRequest())
        first.abort()
        await stopGate.waitUntilEntered()
        let second = Task { try await microphone.start(CaptureRequest()) }
        try await Task.sleep(for: .milliseconds(20))
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        stopGate.open()
        try await microphone.start(CaptureRequest()).stop()
        #expect(opener.log.all == ["open default#1", "stop default#1", "open default#2", "stop default#2"])
    }

    @Test("A capture dropped without stop or abort still releases the device")
    func droppedCapture() async throws {
        let (microphone, opener, _) = makeCapture()
        var capture: (any AudioCapture)? = try await microphone.start(CaptureRequest())
        #expect(capture != nil)
        capture = nil
        try await microphone.start(CaptureRequest()).stop()
        #expect(opener.log.all == ["open default#1", "stop default#1", "open default#2", "stop default#2"])
    }

    @Test("Without microphone access the real capture throws permissionDenied and never prompts",
          .enabled(if: AVCaptureDevice.authorizationStatus(for: .audio) != .authorized,
                   "this process has microphone access; a real capture must not be started in tests"))
    func realCaptureWithoutAccess() async {
        await #expect(throws: CaptureFailure.permissionDenied) {
            try await MicrophoneCapture().start(CaptureRequest())
        }
    }
}

@Suite("Audio input devices")
struct AudioInputDevicesTests {
    @Test("The list has unique identifiers and at most one default, and changes start with it")
    func list() async {
        let devices = AudioInputDevices()
        let now = devices.current()
        #expect(Set(now.map(\.id)).count == now.count)
        #expect(now.filter(\.isDefault).count <= 1)
        var iterator = devices.changes().makeAsyncIterator()
        #expect(await iterator.next() == now)
    }
}
