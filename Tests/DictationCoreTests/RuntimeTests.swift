import DictationCore
import Foundation
import Synchronization
import Testing

/// `SessionRuntime` with fake ports and a manual clock: whole dictations end to end, including cancellation reaching
/// the capture, the stream and the inserter, and the microphone being let go on every path.
@MainActor
@Suite("Session runtime")
struct RuntimeTests {
    @Test func aHoldDictationEndToEnd() async throws {
        let rig = Rig()
        #expect(rig.runtime.handle(.holdPressed, at: rig.clock.now))
        #expect(rig.capturing.requests.isEmpty, "handle only decides; the capture starts after it returns")
        let capture = try await rig.capture(0)
        await rig.waitUntilRecording()
        #expect(rig.speech.options == [SpeechStreamOptions(appBundleID: "com.example.notes")])
        capture.deliver(seconds: 0.5, at: 1000.5)
        capture.deliver(seconds: 0.5, at: 1001)
        rig.runtime.handle(.holdReleased(.keyUp), at: rig.clock.now + 1)
        let stream = try await rig.finishingStream(0)
        #expect(stream.appended.count == 16_000)
        stream.complete("hello there")
        await eventually("the Run Log entry") { rig.history.recorded.count == 1 }

        let text = "v1: hello there (after So )"
        #expect(rig.inserter.transactions == [.init(restoreClipboard: true, composed: ComposedInsertion(text: text))])
        let draft = try #require(rig.history.recorded.first)
        #expect(draft.heard == "hello there" && draft.text == text && draft.outcome == .inserted)
        #expect(draft.samples == samples(1) && draft.date == Rig.date)
        let processed = ProcessedDictation(heard: "hello there", text: text)
        #expect(rig.completions == [DictationCompletion(id: id1, ending: .insertion(.inserted),
                                                        speech: SpeechResult(text: "hello there"),
                                                        processed: processed)])
        #expect(rig.hookCalls.values == [HookCall(id: id1, processed: processed, field: "field-token")])
        #expect(rig.levels.heard == [id1: 16_000] && rig.levels.ended.contains(id1))
        #expect(capture.stops == 1 && capture.aborts == 0)
        #expect(stream.finishes == 1 && !stream.isCancelled)
        #expect(rig.runtime.state.lastText == text)
        #expect(rig.runtime.pill == .hidden)
        rig.expectAllReleased()
    }

    @Test func aStopWhoseLastChunkIsStillQueuedIsTranscribedWhole() async throws {
        let rig = Rig()
        rig.runtime.handle(.togglePressed, at: rig.clock.now)
        let capture = try await rig.capture(0)
        await rig.waitUntilRecording()
        capture.deliver(seconds: 0.5, at: 1000.5)
        capture.queueTail([AudioChunk(samples: samples(0.25, 0.2), time: 1000.75)])
        rig.runtime.handle(.togglePressed, at: rig.clock.now + 1)
        let stream = try await rig.finishingStream(0)
        #expect(stream.appended == samples(0.5) + samples(0.25, 0.2), "the tail arrived before the end was reported")
        stream.complete("tail included")
        await eventually("the Run Log entry") { rig.history.recorded.count == 1 }
        #expect(rig.history.recorded.first?.samples.count == 12_000)
        rig.expectAllReleased()
    }

    @Test func escapeWhileRecordingReleasesEverythingAndKeepsNothing() async throws {
        let rig = Rig()
        rig.runtime.handle(.holdPressed, at: rig.clock.now)
        let capture = try await rig.capture(0)
        await rig.waitUntilRecording()
        capture.deliver(seconds: 1, at: 1001)
        #expect(rig.runtime.handle(.cancelPressed, at: rig.clock.now + 1))
        await eventually("the discard") { rig.completions.count == 1 }
        #expect(rig.completions == [DictationCompletion(id: id1, ending: .discarded)])
        await eventually("the abort") { capture.aborts > 0 }
        let stream = try #require(rig.speech.streams.first)
        #expect(stream.isCancelled && stream.finishes == 0)
        #expect(rig.levels.ended.contains(id1))
        await settle()
        #expect(rig.history.recorded.isEmpty && rig.inserter.transactions.isEmpty)
        rig.expectAllReleased()
    }

    @Test func escapeIsConsumedOnlyWhenSomethingWasCancelled() {
        let rig = Rig()
        #expect(!rig.runtime.handle(.cancelPressed, at: rig.clock.now))
        #expect(!rig.runtime.handle(.pillCancelClicked, at: rig.clock.now))
    }

    @Test func aCaptureThatFinishesStartingAfterItsDictationWasCancelledIsAborted() async throws {
        let rig = Rig()
        rig.capturing.holdStarts = true
        rig.runtime.handle(.togglePressed, at: rig.clock.now)
        await eventually("the start") { rig.capturing.waitingStarts == 1 }
        #expect(rig.runtime.handle(.cancelPressed, at: rig.clock.now + 0.2))
        await eventually("the discard") { rig.completions.count == 1 }
        let late = try #require(rig.capturing.finishStart())
        await eventually("the late capture's abort") { late.aborts == 1 }
        await settle()
        #expect(rig.runtime.state.capture == .idle, "it never reports started")
        #expect(late.stops == 0)
        #expect(rig.speech.streams.first?.isCancelled == true)
        rig.expectAllReleased()
    }

    @Test func aCaptureThatCannotStartShowsTheMicrophoneNotice() async throws {
        let rig = Rig()
        rig.capturing.failNextStart(.deviceUnavailable)
        rig.runtime.handle(.holdPressed, at: rig.clock.now)
        await eventually("the notice") { rig.runtime.state.notice?.message == .microphoneUnavailable }
        #expect(rig.completions.map(\.ending) == [.discarded])
        #expect(rig.speech.streams.first?.isCancelled == true)
        rig.expectAllReleased()
    }

    @Test func theStartTimerGivesUpAndALateCaptureIsAborted() async throws {
        let rig = Rig()
        rig.capturing.holdStarts = true
        rig.runtime.handle(.holdPressed, at: rig.clock.now)
        await eventually("the start timer") { rig.capturing.waitingStarts == 1 && rig.clock.sleepers == 1 }
        rig.clock.advance(by: SessionTiming.captureStart)
        await eventually("the notice") { rig.runtime.state.notice?.message == .microphoneUnavailable }
        let late = try #require(rig.capturing.finishStart())
        await eventually("the abort") { late.aborts == 1 }
        rig.expectAllReleased()
    }

    @Test func theDrainTimerAbortsButKeepsWhatWasDelivered() async throws {
        let rig = Rig()
        rig.runtime.handle(.holdPressed, at: rig.clock.now)
        let capture = try await rig.capture(0)
        await rig.waitUntilRecording()
        capture.stopFinishes(false)
        capture.deliver(seconds: 1, at: 1001)
        rig.runtime.handle(.holdReleased(.keyUp), at: rig.clock.now + 1)
        await eventually("the stop and the drain timer") { capture.stops == 1 && rig.clock.sleepers == 1 }
        rig.clock.advance(by: SessionTiming.captureDrain)
        await eventually("the abort") { capture.aborts > 0 }
        let stream = try await rig.finishingStream(0)
        #expect(stream.appended == samples(1))
        stream.complete("kept")
        await eventually("the Run Log entry") { rig.history.recorded.count == 1 }
        #expect(rig.history.recorded.first?.samples == samples(1))
        rig.expectAllReleased()
    }

    @Test func aNormalEndDisarmsTheDrainTimer() async throws {
        let rig = Rig()
        rig.runtime.handle(.holdPressed, at: rig.clock.now)
        let capture = try await rig.capture(0)
        await rig.waitUntilRecording()
        capture.deliver(seconds: 1, at: 1001)
        rig.runtime.handle(.holdReleased(.keyUp), at: rig.clock.now + 1)
        let stream = try await rig.finishingStream(0)
        await eventually("no timer left") { rig.clock.sleepers == 0 }
        rig.clock.advance(by: SessionTiming.captureDrain)
        await settle()
        #expect(capture.aborts == 0 && stream.finishes == 1)
        stream.complete("once")
        await eventually("the Run Log entry") { rig.history.recorded.count == 1 }
        rig.expectAllReleased()
    }

    @Test func twoDictationsAreInsertedInSpokenOrderWhateverOrderTheirTranscriptsArrive() async throws {
        let rig = Rig()
        for index in 0..<2 {
            rig.runtime.handle(.holdPressed, at: rig.clock.now)
            let capture = try await rig.capture(index)
            await rig.waitUntilRecording()
            capture.deliver(seconds: 1, at: rig.clock.now)
            rig.runtime.handle(.holdReleased(.keyUp), at: rig.clock.now + 1)
            _ = try await rig.finishingStream(index)
        }
        rig.speech.streams[1].complete("second")
        await settle()
        #expect(rig.inserter.transactions.isEmpty, "the second waits for the first")
        rig.speech.streams[0].complete("first")
        await eventually("both inserted") { rig.inserter.transactions.count == 2 }
        #expect(rig.inserter.transactions.map(\.composed.text) == ["v1: first (after So )",
                                                                  "v1: second (after So )"])
        await eventually("both completed") { rig.completions.count == 2 }
        rig.expectAllReleased()
    }

    @Test func thePermissionPromptStartsAPressStillHeld() async throws {
        let rig = Rig(microphone: .unknown)
        rig.runtime.handle(.holdPressed, at: rig.clock.now)
        await eventually("the prompt") { rig.microphone.isAsking }
        #expect(rig.runtime.pill == .hidden)
        rig.app.set(AppIdentity(bundleID: "com.example.mail", name: "Mail"))
        rig.microphone.answer(.granted)
        let capture = try await rig.capture(0)
        #expect(rig.speech.options.first?.appBundleID == "com.example.mail", "the app in front when it started")
        await rig.waitUntilRecording()
        rig.runtime.handle(.cancelPressed, at: rig.clock.now + 2)
        await eventually("the abort") { capture.aborts > 0 }
        rig.expectAllReleased()
    }

    @Test func thePermissionPromptAnsweredAfterTheReleaseStartsNothing() async {
        let rig = Rig(microphone: .unknown)
        rig.runtime.handle(.holdPressed, at: rig.clock.now)
        await eventually("the prompt") { rig.microphone.isAsking }
        rig.runtime.handle(.holdReleased(.keyUp), at: rig.clock.now + 1)
        rig.microphone.answer(.granted)
        await eventually("the answer") { rig.runtime.state.microphone == .granted }
        await settle()
        #expect(rig.capturing.requests.isEmpty)
        #expect(rig.microphone.requests == 1)
        rig.expectAllReleased()
    }

    @Test func aClipboardOnlyDestinationGetsNoContextAndNoField() async throws {
        let rig = Rig(autoResult: .success(SpeechResult(text: "copied text")))
        rig.inserter.setDestination(.clipboard(.accessibilityMissing))
        try await rig.dictate()
        await eventually("the notice") { rig.runtime.state.notice?.message == .leftOnClipboard(.accessibilityMissing) }
        #expect(rig.inserter.transactions.map(\.composed.text) == ["v1: copied text"])
        #expect(rig.hookCalls.values.map(\.field) == [nil])
        #expect(rig.history.recorded.map(\.outcome) == [.leftOnClipboard])
        rig.expectAllReleased()
    }

    @Test func pasteAgainComposesTheRememberedTextVerbatim() async throws {
        let rig = Rig(autoResult: .success(SpeechResult(text: "send it press enter")))
        try await rig.dictate()
        #expect(rig.inserter.transactions.map(\.composed)
                == [ComposedInsertion(text: "v1: send it (after So )", pressEnter: true)])
        #expect(rig.runtime.handle(.pasteAgainPressed, at: rig.clock.now + 10))
        await eventually("the replay") { rig.inserter.transactions.count == 2 }
        #expect(rig.inserter.transactions.last?.composed
                == ComposedInsertion(text: "v1: send it (after So )", pressEnter: false))
        await eventually("the output freed") { rig.runtime.state.output == .free }
        #expect(rig.hookCalls.values.count == 1 && rig.history.recorded.count == 1 && rig.completions.count == 1)
        rig.expectAllReleased()
    }

    @Test func pasteAgainDuringAnInsertionDoesNothing() async throws {
        let rig = Rig(autoResult: .success(SpeechResult(text: "first")))
        try await rig.dictate()
        rig.inserter.holdTransactions = true
        rig.speech.setAutoResult(.success(SpeechResult(text: "second")))
        try await rig.dictate(waitForEntry: false)
        await eventually("the held transaction") { rig.inserter.waiting == 1 }
        #expect(!rig.runtime.handle(.pasteAgainPressed, at: rig.clock.now + 20))
        #expect(!rig.runtime.handle(.cancelPressed, at: rig.clock.now + 20), "an insertion is never cancelled")
        rig.inserter.releaseTransaction()
        await eventually("the second entry") { rig.history.recorded.count == 2 }
        await settle()
        #expect(rig.inserter.transactions.count == 2 && rig.inserter.waiting == 0)
        rig.expectAllReleased()
    }

    @Test func aDiscardWhileTranscribingCancelsTheStream() async throws {
        let rig = Rig()
        rig.runtime.handle(.holdPressed, at: rig.clock.now)
        let capture = try await rig.capture(0)
        await rig.waitUntilRecording()
        capture.deliver(seconds: 1, at: 1001)
        rig.runtime.handle(.holdReleased(.keyUp), at: rig.clock.now + 1)
        let stream = try await rig.finishingStream(0)
        #expect(rig.runtime.handle(.cancelPressed, at: rig.clock.now + 2))
        await eventually("the cancel") { stream.isCancelled }
        await settle()
        #expect(rig.completions.map(\.ending) == [.discarded])
        #expect(rig.history.recorded.isEmpty && rig.inserter.transactions.isEmpty)
        rig.expectAllReleased()
    }

    @Test func aFailedTranscriptIsRecordedWithItsAudio() async throws {
        let rig = Rig(autoResult: .failure(.failed))
        try await rig.dictate()
        #expect(rig.history.recorded.map(\.outcome) == [.transcriptionFailed])
        #expect(rig.history.recorded.first?.samples == samples(1))
        #expect(rig.runtime.state.notice?.message == .transcriptionFailed)
        rig.expectAllReleased()
    }

    @Test func theTextRulesAreTheOnesInForceWhenTheDictationStarted() async throws {
        let rig = Rig()
        rig.runtime.handle(.holdPressed, at: rig.clock.now)
        let capture = try await rig.capture(0)
        await rig.waitUntilRecording()
        rig.rules.value = LabelRules(label: "v2")
        capture.deliver(seconds: 1, at: 1001)
        rig.runtime.handle(.holdReleased(.keyUp), at: rig.clock.now + 1)
        try await rig.finishingStream(0).complete("words")
        await eventually("the first entry") { rig.history.recorded.count == 1 }
        rig.speech.setAutoResult(.success(SpeechResult(text: "more")))
        try await rig.dictate()
        #expect(rig.inserter.transactions.map(\.composed.text) == ["v1: words (after So )", "v2: more (after So )"])
        rig.expectAllReleased()
    }

    @Test func settingsAreReadForEachDictation() async throws {
        let rig = Rig(autoResult: .success(SpeechResult(text: "words")))
        rig.settings.value = SessionSettings(restoreClipboard: false, microphoneID: "usb-mic", retainForCorrection: true)
        try await rig.dictate()
        #expect(rig.capturing.requests == [CaptureRequest(deviceID: "usb-mic")])
        #expect(rig.speech.options.first?.retainForCorrection == true)
        #expect(rig.inserter.transactions.first?.restoreClipboard == false)
        rig.expectAllReleased()
    }

    @Test func engineReadinessFollowsTheEngineAndCanBeRetried() async {
        let rig = Rig()
        await eventually("the first preparation") { rig.speech.prepares == 1 }
        rig.speech.report(.failed(.loadFailed))
        await eventually("the failure") { rig.runtime.state.engine == .failed(.loadFailed) }
        rig.runtime.retryPreparation()
        await eventually("the retry") { rig.speech.prepares == 2 }
        rig.speech.report(.ready)
        await eventually("ready") { rig.runtime.state.engine == .ready }
        rig.runtime.start()
        await settle()
        #expect(rig.speech.prepares == 2, "start only works once")
    }

    @Test func noticesExpireOnTheClock() async {
        let rig = Rig(microphone: .denied)
        rig.runtime.handle(.holdPressed, at: rig.clock.now)
        #expect(rig.runtime.state.notice?.message == .microphoneDenied)
        await eventually("the notice timer") { rig.clock.sleepers == 1 }
        rig.clock.advance(by: SessionTiming.errorNotice)
        await eventually("the expiry") { rig.runtime.state.notice == nil }
    }

    @Test func refreshingTheMicrophoneAccessPicksUpAChangeInSystemSettings() async throws {
        let rig = Rig(microphone: .denied)
        rig.microphone.set(.granted)
        rig.runtime.refreshMicrophoneAccess()
        rig.runtime.handle(.togglePressed, at: rig.clock.now)
        let capture = try await rig.capture(0)
        rig.runtime.handle(.cancelPressed, at: rig.clock.now)
        await eventually("the abort") { capture.aborts > 0 }
        rig.expectAllReleased()
    }

    @Test func forgettingTheLastTextDisablesPasteAgain() async throws {
        let rig = Rig(autoResult: .success(SpeechResult(text: "words")))
        try await rig.dictate()
        rig.runtime.forgetLast()
        #expect(!rig.runtime.handle(.pasteAgainPressed, at: rig.clock.now + 10))
    }
}

// MARK: - The rig

/// A runtime wired to fakes, with the hooks recorded.
@MainActor
final class Rig {
    nonisolated static let date = Date(timeIntervalSince1970: 1_800_000_000)

    let clock: ManualClock
    let capturing: FakeCapturing
    let speech: FakeSpeech
    let inserter: FakeInserter
    let microphone: FakeMicrophone
    let app: FakeFrontmostApp
    let history: FakeHistory
    let levels: FakeLevels
    let settings: Shared<SessionSettings>
    let rules: Shared<any TranscriptProcessing>
    let hookCalls: Recorded<HookCall>
    private(set) var completions: [DictationCompletion] = []
    let runtime: SessionRuntime

    init(microphone access: MicrophoneAccess = .granted, autoResult: Result<SpeechResult, SpeechFailure>? = nil) {
        let clock = ManualClock(), capturing = FakeCapturing(), speech = FakeSpeech(autoResult: autoResult)
        let inserter = FakeInserter(), microphone = FakeMicrophone(access), app = FakeFrontmostApp()
        let history = FakeHistory(), levels = FakeLevels(), hookCalls = Recorded<HookCall>()
        let settings = Shared(SessionSettings())
        let rules = Shared<any TranscriptProcessing>(LabelRules(label: "v1"))
        (self.clock, self.capturing, self.speech, self.inserter) = (clock, capturing, speech, inserter)
        (self.microphone, self.app, self.history, self.levels) = (microphone, app, history, levels)
        (self.settings, self.rules, self.hookCalls) = (settings, rules, hookCalls)
        runtime = SessionRuntime(
            ports: SessionPorts(capture: capturing, speech: speech, inserter: inserter, microphone: microphone,
                                frontmostApp: app, history: history, levels: levels, clock: clock),
            settings: { settings.value }, textRules: { rules.value }, date: { Rig.date })
        runtime.willInsert = { id, processed, destination in
            var field: String?
            if case .cursor(_, let token?) = destination { field = token.value as? String }
            hookCalls.append(HookCall(id: id, processed: processed, field: field))
        }
        runtime.onCompletion = { [weak self] completion in self?.completions.append(completion) }
        runtime.start()
    }

    /// The capture the `index`th start returned, once it exists.
    func capture(_ index: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws -> FakeCapture {
        await eventually("capture \(index)", sourceLocation: sourceLocation) { capturing.captures.count > index }
        return try #require(capturing.captures.dropFirst(index).first, sourceLocation: sourceLocation)
    }

    func waitUntilRecording(sourceLocation: SourceLocation = #_sourceLocation) async {
        await eventually("recording", sourceLocation: sourceLocation) {
            if case .recording = runtime.state.capture { true } else { false }
        }
    }

    /// The `index`th stream, once its `finish` has been called.
    func finishingStream(_ index: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws -> FakeStream {
        await eventually("stream \(index) finishing", sourceLocation: sourceLocation) {
            speech.streams.count > index && speech.streams[index].finishes == 1
        }
        return try #require(speech.streams.dropFirst(index).first, sourceLocation: sourceLocation)
    }

    /// A one-second hold dictation, answered by the speech fake's automatic result.
    func dictate(waitForEntry: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let entries = history.recorded.count
        let index = capturing.captures.count
        runtime.handle(.holdPressed, at: clock.now)
        let capture = try await capture(index, sourceLocation: sourceLocation)
        await waitUntilRecording(sourceLocation: sourceLocation)
        capture.deliver(seconds: 1, at: clock.now)
        runtime.handle(.holdReleased(.keyUp), at: clock.now + 1)
        if waitForEntry {
            await eventually("the Run Log entry", sourceLocation: sourceLocation) {
                history.recorded.count > entries && runtime.state.output == .free
            }
        }
    }

    /// Every capture let go of the microphone, every stream was finished or cancelled, and no dictation is left.
    func expectAllReleased(sourceLocation: SourceLocation = #_sourceLocation) {
        for (index, capture) in capturing.captures.enumerated() {
            #expect(capture.isReleased, "capture \(index) still holds the microphone", sourceLocation: sourceLocation)
        }
        for (index, stream) in speech.streams.enumerated() {
            #expect(stream.finishes == 1 || stream.isCancelled, "stream \(index) left open",
                    sourceLocation: sourceLocation)
        }
        #expect(runtime.state.dictationCount == 0 && runtime.state.capture.live == nil,
                sourceLocation: sourceLocation)
        #expect(runtime.state.output == .free, sourceLocation: sourceLocation)
    }
}

struct HookCall: Equatable, Sendable {
    var id: DictationID
    var processed: ProcessedDictation
    var field: String?
}

/// A value the test changes and the runtime's closures read.
@MainActor
final class Shared<Value> {
    var value: Value

    init(_ value: Value) { self.value = value }
}

/// Values appended from any thread.
final class Recorded<Element: Sendable>: Sendable {
    private let storage = Mutex<[Element]>([])

    var values: [Element] { storage.withLock { $0 } }

    func append(_ element: Element) { storage.withLock { $0.append(element) } }
}
