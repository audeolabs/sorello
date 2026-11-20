#if SORELLO_KEYBOARD_DICTATION
import Foundation
import TextRules
import UIKit

/// The in-keyboard dictation of one keyboard instance (ARCHITECTURE.md, "In-keyboard dictation (experiment)"): it feeds
/// `KeyboardDictationMachine` the user's taps, the capture's messages, the transcription's reports and the clock, and
/// carries out the effects it returns, in order: capture (`WebAudioCapture`), the audio pipeline, the transcription
/// (`KeyboardSpeech`) and `keyboard-dictation.json`. The decisions are the machine's.
@MainActor
final class KeyboardLocalDictation {
    /// What it needs from the dictation client.
    struct Hooks {
        /// The view the capture's web view is added to while it runs.
        var container: () -> UIView?
        /// A freshly read status shows the host owning the microphone (`KeyboardDictationRoute.hostOwnsMicrophone`).
        var hostOwnsMicrophone: () -> Bool
        /// The text rules' options, as the host uses them, from the shared settings.
        var ruleOptions: () -> TextRuleOptions
        /// Nothing was heard: go on as a host tap would, if the keyboard still shows the tap's field (its identity given).
        var handToHost: (UUID) -> Void
        /// "No speech detected".
        var noSpeech: () -> Void
        /// A chunk's level, for the wave.
        var level: (Float) -> Void
        /// The mode or the waiting text may have changed.
        var changed: () -> Void
    }

    /// A random id of this keyboard process, in memory only, naming nothing (the record's `processID`).
    static let processID = UUID()

    private let store: SharedDictationStore
    private let speech: KeyboardSpeech
    private let hooks: Hooks
    /// Nil in the keyboard, which takes the page for "Use iPhone microphone" at each tap; a verification harness, never
    /// the keyboard, passes a synthetic source.
    private let capturePageOverride: String?
    /// The page the current attempt's capture loads, chosen at its tap.
    private var capturePage = CapturePage.html
    private var machine = KeyboardDictationMachine()
    private var capture: WebAudioCapture?
    /// The held microphone (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Capture, Held microphone): a capture
    /// opened before the tap, posting nothing until the tap's dictation takes it. Its token names it to its own grants.
    private var heldCapture: WebAudioCapture?
    private var heldToken: UUID?
    /// A held capture reported something since the keyboard appeared: no holding again until it next appears.
    private(set) var heldCaptureReported = false
    private var pipeline: KeyboardAudioPipeline?
    private var transcription: KeyboardTranscription?
    private var meter: LevelMeter?
    /// The attempt's input levels, for the record (accepted chunks only, until the seal).
    private var inputLevels = KeyboardInputLevels()
    private var timer: Timer?
    /// The last attempt's record, as this keyboard last wrote it, with its monotonic tap and stop.
    private var record: KeyboardDictationRecord?
    private var tappedAt: TimeInterval = 0
    private var stoppedAt: TimeInterval?
    private var schedule = KeyboardDictationRecordSchedule()

    init(store: SharedDictationStore, modelDirectory: URL, hooks: Hooks, capturePage: String? = nil) {
        self.store = store
        capturePageOverride = capturePage
        speech = KeyboardSpeech(modelDirectory: modelDirectory)
        self.hooks = hooks
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var isRunning: Bool { machine.isRunning }
    /// The held microphone is open.
    var isHolding: Bool { heldCapture != nil }
    /// A dictation's capture is open: it is starting or recording.
    var isCapturing: Bool { machine.isCaptureOpen }
    var runningAttemptID: UUID? { machine.runningAttemptID }
    var lastEndedCaptureUnavailable: Bool { machine.lastEndedCaptureUnavailable }
    /// The top row's mode for it, or nil when the host's applies.
    var mode: KeyboardMode? { machine.mode(at: Self.now, wallNow: Date()) }
    /// The unbound text the chip may offer.
    var offeredText: DictationResult? { machine.offeredText }
    /// The oldest bound text still fresh: the next to insert, then taken by its id (`takeBoundText(_:)`).
    var nextBoundText: DictationResult? { machine.boundText(at: Self.now) }

    // MARK: Inputs

    /// `useBuiltInMicrophone`: the shared setting, read at this tap (ARCHITECTURE.md, "In-keyboard dictation
    /// (experiment)", Capture).
    func start(documentID: UUID?, useBuiltInMicrophone: Bool) {
        capturePage = capturePageOverride ?? CapturePage.page(useBuiltInMicrophone: useBuiltInMicrophone)
        handle(.tap(attempt: UUID(), documentID: documentID))
    }

    /// Stop on the attempt the bar showed. Returns whether the machine took it, after judging the clock: it sealed the
    /// recording, or cancelled an attempt that had heard nothing.
    @discardableResult
    func stop(_ attemptID: UUID) -> Bool {
        let effects = handle(.stop(attempt: attemptID))
        return effects.contains(.seal(attemptID)) || effects.contains(.outcome(.cancelled, attemptID))
    }

    func cancel(_ attemptID: UUID) { handle(.cancel(attempt: attemptID)) }

    /// Opens or closes the held microphone, as `KeyboardMicrophoneHold.shouldHold` judged at this pass. Never while a
    /// dictation's capture is open, and never with a harness's page.
    func hold(_ shouldHold: Bool) {
        guard shouldHold, !machine.isCaptureOpen, !heldCaptureReported, capturePageOverride == nil else { return releaseHold() }
        guard heldCapture == nil, let container = hooks.container() else { return }
        let token = UUID()
        let held = WebAudioCapture(
            page: CapturePage.heldMicrophoneHTML,
            mayGrantMicrophone: { [weak self] in
                guard let self else { return false }
                return heldToken == token && !machine.isCaptureOpen && !hooks.hostOwnsMicrophone()
            },
            // Held, the page posts nothing; anything it reports ends the hold until the keyboard next appears.
            onMessage: { [weak self] _ in
                guard let self, heldToken == token else { return }
                heldCaptureReported = true
                releaseHold()
            })
        heldCapture = held
        heldToken = token
        held.open(in: container)
    }

    private func releaseHold() {
        heldCapture?.close()
        heldCapture = nil
        heldToken = nil
    }

    /// The keyboard is hiding: the dictation ends, its text goes, and the engine is released once its work has ended.
    func hide() {
        releaseHold()
        heldCaptureReported = false
        handle(.hide)
        timer?.invalidate()
        timer = nil
        speech.release()
    }

    func focus(_ documentID: UUID?) { handle(.focus(documentID: documentID)) }

    func hostOwnsMicrophone() { handle(.hostOwnsMicrophone) }

    /// A memory warning is counted while a dictation runs and does not end it; otherwise the engine is released.
    func memoryWarning() {
        guard machine.isRunning, var record else { return speech.release() }
        record.memoryWarnings = (record.memoryWarnings ?? 0) + 1
        self.record = record
        schedule.figuresChanged()
        writeIfDue()
    }

    /// The bound text of `attemptID`, for insertion now: taken at most once, and never past `resultTTL`.
    func takeBoundText(_ attemptID: UUID) -> DictationResult? {
        defer { scheduleTimer() }
        return machine.takeBoundText(attemptID, at: Self.now)
    }

    /// The chip's text, if it still waits under the id the chip showed.
    func takeOfferedText(_ attemptID: UUID) -> DictationResult? {
        defer { scheduleTimer() }
        return machine.takeOfferedText(attemptID, at: Self.now)
    }

    /// The host owns the microphone as a text would be delivered: it is dropped, never inserted.
    func dropText(_ attemptID: UUID) {
        for effect in machine.dropText(attemptID) { apply(effect) }
        scheduleTimer()
        hooks.changed()
    }

    /// The text of `attemptID` went into the field.
    func inserted(_ attemptID: UUID) {
        let now = Self.now
        guard record?.attemptID == attemptID else { return }
        if let stoppedAt { record?.stopToInsertionMilliseconds = (now - stoppedAt) * 1_000 }
        reach(.inserted, at: now)
    }

    // MARK: The machine

    @discardableResult
    private func handle(_ event: KeyboardDictationMachine.Event) -> [KeyboardDictationMachine.Effect] {
        let effects = machine.handle(event, at: Self.now)
        for effect in effects { apply(effect) }
        scheduleTimer()
        if !effects.isEmpty || event == .tick { hooks.changed() }
        return effects
    }

    private func apply(_ effect: KeyboardDictationMachine.Effect) {
        let now = Self.now
        switch effect {
        case .step(let step, let id):
            if step == .tapped { begin(id, at: now) }
            guard record?.attemptID == id else { return }
            if step == .stopped { stoppedAt = now }
            if step == .transcribed, let stoppedAt { record?.stopToTextMilliseconds = (now - stoppedAt) * 1_000 }
            reach(step, at: now)
        case .outcome(let outcome, let id):
            guard record?.attemptID == id else { return }
            record?.end(outcome, milliseconds: (now - tappedAt) * 1_000, memory: KeyboardMemory.sample())
            write()
        case .openCapture(let id):
            openCapture(id)
        case .loadModel(let id):
            loadModel(id)
        case .seal(let id):
            capture?.close()
            capture = nil
            pipeline?.seal { [weak self] seconds, rate in
                Task { @MainActor in self?.sealed(id, seconds: seconds, rate: rate) }
            }
        case .tearDown:
            tearDown()
        case .handToHost(let documentID):
            hooks.handToHost(documentID)
        case .noSpeech:
            hooks.noSpeech()
        }
    }

    /// The tap: a new record, with a new attempt id, over the last one.
    private func begin(_ id: UUID, at now: TimeInterval) {
        tappedAt = now
        stoppedAt = nil
        schedule = KeyboardDictationRecordSchedule()
        record = KeyboardDictationRecord(attemptID: id, processID: Self.processID, tappedAt: Date(),
                                         iosVersion: UIDevice.current.systemVersion, warm: speech.isWarm)
    }

    private func openCapture(_ id: UUID) {
        let pipeline = KeyboardAudioPipeline()
        self.pipeline = pipeline
        meter = nil
        inputLevels = KeyboardInputLevels()
        let mayGrantMicrophone: () -> Bool = { [weak self] in
            guard let self else { return false }
            return machine.runningAttemptID == id && machine.isCaptureOpen && !hooks.hostOwnsMicrophone()
        }
        let onMessage: (CaptureMessageReader.Message) -> Void = { [weak self] message in self?.received(message, for: id) }
        // The held microphone chose the iPhone's as the built-in page would: the tap's dictation takes it and records
        // from now on (from when its page has loaded). Otherwise the hold goes first: a new capture needs its microphone.
        if let held = heldCapture, held.isOpen, capturePage == CapturePage.builtInMicrophoneHTML {
            heldCapture = nil
            heldToken = nil
            held.handOver(mayGrantMicrophone: mayGrantMicrophone, onMessage: onMessage)
            capture = held
            return
        }
        releaseHold()
        let capture = WebAudioCapture(page: capturePage, mayGrantMicrophone: mayGrantMicrophone, onMessage: onMessage)
        self.capture = capture
        guard let container = hooks.container() else {
            DispatchQueue.main.async { [weak self] in self?.handle(.captureFailed(attempt: id)) }
            return
        }
        capture.open(in: container)
    }

    private func loadModel(_ id: UUID) {
        guard let pipeline else { return }
        let transcription = KeyboardTranscription(speech: speech, pipeline: pipeline) { [weak self] report in
            self?.reported(report, for: id)
        }
        self.transcription = transcription
        transcription.start()
    }

    private func received(_ message: CaptureMessageReader.Message, for id: UUID) {
        guard machine.runningAttemptID == id, machine.isCaptureOpen else { return }
        switch message {
        case let .audio(samples, rate, input):
            var meter = self.meter ?? LevelMeter.keyboardCapture(sampleRate: rate)
            meter.update(with: samples)
            // The machine judges the clock first: a chunk after the maximum duration or the audio gap finds capture
            // closed and is not kept.
            handle(.audio(attempt: id, level: meter.level))
            guard machine.runningAttemptID == id, machine.isCaptureOpen else { return }
            guard let pipeline, pipeline.accept(samples, rate: rate, converted: { [weak self] in
                Task { @MainActor in self?.converted(id) }
            }) else { handle(.captureFailed(attempt: id)); return }
            self.meter = meter
            if let input { record?.captureInput = input }
            inputLevels.add(samples, rate: rate)
            hooks.level(meter.level)
        case .failed, .ended, .malformed:
            handle(.captureFailed(attempt: id))
        }
    }

    /// A chunk was converted: the memory then, written at most once a second when it changed.
    private func converted(_ id: UUID) {
        guard machine.runningAttemptID == id, record?.attemptID == id else { return }
        if record?.note(KeyboardMemory.sample()) == true { schedule.figuresChanged() }
        writeIfDue()
    }

    private func sealed(_ id: UUID, seconds: Double, rate: Double?) {
        guard machine.runningAttemptID == id, record?.attemptID == id else { return }
        record?.audioSeconds = seconds
        record?.captureSampleRate = rate
        record?.inputLoudestDBFS = inputLevels.loudestDBFS
        record?.inputTypicalDBFS = inputLevels.typicalDBFS
    }

    private func reported(_ report: KeyboardTranscription.Report, for id: UUID) {
        guard machine.runningAttemptID == id else { return }
        switch report {
        case .modelLoading:
            handle(.modelLoading(attempt: id))
        case .modelReady(let milliseconds):
            record?.preparationMilliseconds = milliseconds
            handle(.modelReady(attempt: id))
        case .modelFailed:
            handle(.modelFailed(attempt: id))
        case .firstChunkDecoded:
            handle(.firstChunkDecoded(attempt: id))
        case .failed:
            handle(.transcriptionFailed(attempt: id))
        case .transcribed(let text, let source):
            // Checked again before the text is delivered: the host may have taken the microphone meanwhile.
            guard !hooks.hostOwnsMicrophone() else { handle(.hostOwnsMicrophone); return }
            if let transcription { speech.attemptEnding(after: transcription.ended()) }
            transcription = nil
            pipeline = nil
            record?.textSource = source
            let processed = DictationRules.process(text, options: hooks.ruleOptions(), promptStyle: false)
            let result = DictationResult(requestID: id, hostRunID: Self.processID, text: processed.text,
                                         pressEnter: processed.pressEnter, createdAt: Date())
            handle(.transcribed(attempt: id, result: result))
        }
    }

    /// Every end: capture torn down at once, the recording dropped, the transcription cancelled.
    private func tearDown() {
        capture?.close()
        capture = nil
        pipeline?.cancel()
        pipeline = nil
        if let transcription { speech.attemptEnding(after: transcription.cancel()) }
        transcription = nil
        meter = nil
    }

    // MARK: The record

    private func reach(_ step: KeyboardDictationRecord.Step, at now: TimeInterval) {
        record?.reach(step, milliseconds: (now - tappedAt) * 1_000, memory: KeyboardMemory.sample())
        if step == .tapped {
            // Only the tap starts a record; a failed write does not affect the dictation.
            if let record { try? store.writeKeyboardDictation(record) }
            schedule.wrote(at: now)
        } else {
            write()
        }
    }

    /// Every write after the tap's replaces the record only while it is still this attempt's and not abandoned.
    private func write() {
        guard let record else { return }
        store.replaceKeyboardDictation(record)
        schedule.wrote(at: Self.now)
    }

    private func writeIfDue() {
        guard machine.phase == .recording, schedule.isDue(at: Self.now), let record else { return }
        store.replaceKeyboardDictation(record)
    }

    // MARK: The clock

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard let deadline = machine.nextDeadline else { return }
        timer = Timer.mainLoop(after: max(deadline - Self.now, 0) + 0.01) { [weak self] _ in
            self?.handle(.tick)
        }
    }
}
#endif
