#if SORELLO_KEYBOARD_DICTATION
import DictationCore
import DictionaryKit
import Foundation
import SpeechEngine

/// The keyboard's `SpeechEngine` over the model the app carries (ARCHITECTURE.md, "In-keyboard dictation (experiment)",
/// Transcription): loaded where it lies in the app, with no store, on the Neural Engine, with an empty dictionary (the
/// entries never leave the app). It stays loaded while this keyboard instance is visible, so the next dictation starts
/// warm, and is released when asked once any model work has ended. A new engine is made, and a new attempt touches it,
/// only after the last attempt's model work has ended.
@MainActor
final class KeyboardSpeech {
    /// `Sorello.app/Model/`, from the keyboard's bundle (`Sorello.app/PlugIns/SorelloKeyboard.appex`), when its
    /// `bundle.json` is readable; nil otherwise.
    static func carriedModel(keyboardBundle: URL = Bundle.main.bundleURL) -> URL? {
        let model = keyboardBundle.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Model", isDirectory: true)
        return FileManager.default.isReadableFile(atPath: model.appendingPathComponent("bundle.json").path) ? model : nil
    }

    private let modelDirectory: URL
    private var engine: SpeechEngine?
    /// Whether an attempt that uses `engine` starts warm (`KeyboardEngineWarmth`).
    private var warmth = KeyboardEngineWarmth()
    /// Every attempt's end and every release, in order (`KeyboardWorkLine`).
    private let work = KeyboardWorkLine()

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    /// An engine is loaded and prepared, and not on its way out: an attempt now starts warm.
    var isWarm: Bool { warmth.isWarm }

    /// The engine for an attempt, once every earlier attempt's model work and every release asked for have ended: the
    /// loaded one, or a new one. Nil, making nothing, when the calling task was cancelled meanwhile.
    func engineWhenFree() async -> SpeechEngine? {
        guard await work.waitUntilFree(), !Task.isCancelled else { return nil }
        if let engine { return engine }
        let engine = SpeechEngine(modelDirectory: modelDirectory, storeDirectory: nil, compute: .neuralEngine,
                                  dictionary: { _ in .empty })
        self.engine = engine
        warmth.made(ObjectIdentifier(engine))
        return engine
    }

    /// `engine` prepared successfully.
    func prepared(_ engine: SpeechEngine) {
        warmth.prepared(ObjectIdentifier(engine))
    }

    /// An attempt ended: the next waits until `ended` is done and the engine's model work has drained.
    func attemptEnding(after ended: Task<Void, Never>) {
        let engine = self.engine
        work.then {
            await ended.value
            await engine?.waitUntilModelWorkEnds()
        }
    }

    /// Releases the engine and its model once any preparation or model work has ended. From now on a tap is cold.
    func release() {
        let engine = self.engine
        let identity = engine.map(ObjectIdentifier.init)
        warmth.releaseRequested(identity)
        work.then { [weak self] in
            await engine?.waitUntilModelWorkEnds()
            // Only the engine this release was asked for; one made since stays.
            if let self, self.warmth.released(identity) { self.engine = nil }
        }
    }
}

/// Where a text came from.
typealias KeyboardTextSource = KeyboardDictationRecord.TextSource

/// One attempt's transcription: preparation from the tap, a stream once the model is ready that the audio pipeline
/// feeds, `finish` against the sealed recording, and one batch of the same recording if the stream fails other than by
/// cancellation. After `cancel`, nothing it reports reaches anyone.
@MainActor
final class KeyboardTranscription {
    enum Report: Sendable {
        case modelLoading
        case modelReady(preparationMilliseconds: Double)
        case modelFailed
        case firstChunkDecoded
        case transcribed(String, KeyboardTextSource)
        case failed
    }

    private let speech: KeyboardSpeech
    private let pipeline: KeyboardAudioPipeline
    private var report: ((Report) -> Void)?
    private var engine: SpeechEngine?
    private var stream: (any SpeechStreaming)?
    private var tasks: [Task<Void, Never>] = []
    private var finishing = false

    init(speech: KeyboardSpeech, pipeline: KeyboardAudioPipeline, report: @escaping (Report) -> Void) {
        self.speech = speech
        self.pipeline = pipeline
        self.report = report
    }

    /// Loads the model, or waits for the loaded one, beside capture; streams once it is ready.
    func start() {
        tasks.append(Task { [weak self] in
            guard let speech = self?.speech else { return }
            guard let engine = await speech.engineWhenFree(), let self, self.report != nil else { return }
            self.engine = engine
            self.report?(.modelLoading)
            let started = ProcessInfo.processInfo.systemUptime
            await engine.prepare()
            var readiness = EngineReadiness.preparing
            for await current in engine.readiness() {
                readiness = current
                break
            }
            guard self.report != nil else { return }
            guard readiness == .ready else {
                self.report?(.modelFailed)
                return
            }
            self.speech.prepared(engine)
            self.report?(.modelReady(preparationMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000))
            // The report may have ended the attempt (a deadline judged first): then no stream is opened.
            guard self.report != nil, !Task.isCancelled else { return }
            // Nothing is retained for a correction. Progress is asked for only to learn when the first chunk is
            // decoded; its text is never kept.
            let stream = engine.openStream(SpeechStreamOptions(reportsProgress: true))
            self.stream = stream
            if let progress = stream.progress {
                self.tasks.append(Task { [weak self] in
                    var first = true
                    for await _ in progress where first {
                        first = false
                        self?.report?(.firstChunkDecoded)
                    }
                })
            }
            self.pipeline.attach(stream) { [weak self] samples in
                Task { @MainActor in self?.finish(stream: stream, recording: samples) }
            }
        })
    }

    /// The sealed recording is all in the stream: its text, or one batch of the same recording.
    private func finish(stream: any SpeechStreaming, recording: [Float]) {
        guard report != nil, !finishing, let engine else { return }
        finishing = true
        tasks.append(Task { [weak self] in
            do {
                let result = try await stream.finish()
                self?.report?(.transcribed(result.text, .stream))
            } catch {
                guard self?.report != nil, (error as? SpeechFailure) != .cancelled else { return }
                await engine.waitUntilModelWorkEnds()
                guard self?.report != nil else { return }
                do {
                    let text = try await engine.transcribe(recording)
                    self?.report?(.transcribed(text, .batch))
                } catch {
                    self?.report?(.failed)
                }
            }
        })
    }

    /// Ends it: the stream is cancelled, and nothing it reports afterwards reaches anyone. Returns a task that ends
    /// once its own work has.
    @discardableResult
    func cancel() -> Task<Void, Never> {
        report = nil
        stream?.cancel()
        stream = nil
        let running = tasks
        tasks = []
        running.forEach { $0.cancel() }
        return Task { for task in running { await task.value } }
    }

    /// The text came, or it failed: its tasks are done with; the next attempt waits for the engine's work to end.
    func ended() -> Task<Void, Never> {
        report = nil
        stream = nil
        let running = tasks
        tasks = []
        return Task { for task in running { await task.value } }
    }
}

/// The audio between the page and the engine (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Capture): each
/// accepted chunk is converted on a queue of its own into the `KeyboardRecording`, at most `maxQueuedAudio` of accepted
/// audio waiting unconverted, and handed to the stream once one is attached. The seal converts what was accepted before
/// it, once; then, once a stream is attached too, the recording is all in the stream and `ready` is called with it.
final class KeyboardAudioPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sorello.keyboard.audio", qos: .userInitiated)
    private let lock = NSLock()
    /// Accepted but not yet converted, in seconds; under `lock`.
    private var queuedSeconds = 0.0
    // Confined to `queue`.
    private var recording = KeyboardRecording()
    private var stream: (any SpeechStreaming)?
    private var ready: (@Sendable ([Float]) -> Void)?
    private var sealed: (@Sendable (_ seconds: Double, _ rate: Double?) -> Void)?
    private var cancelled = false

    /// Accepts a chunk for conversion; false, taking nothing, when more than `maxQueuedAudio` would wait.
    /// `converted` runs on the queue once it is converted.
    func accept(_ chunk: [Float], rate: Double, converted: @escaping @Sendable () -> Void) -> Bool {
        let seconds = Double(chunk.count) / rate
        lock.lock()
        let fits = queuedSeconds + seconds <= KeyboardDictationTiming.maxQueuedAudio
        if fits { queuedSeconds += seconds }
        lock.unlock()
        guard fits else { return false }
        queue.async { [self] in
            defer {
                lock.lock()
                queuedSeconds -= seconds
                lock.unlock()
            }
            guard !cancelled, recording.append(chunk, rate: rate) else { return }
            feed()
            converted()
        }
        return true
    }

    /// The stream, once the model is ready: it takes all the recording so far, then each chunk. `ready` gets the
    /// sealed recording once both the seal and the stream have come.
    func attach(_ stream: any SpeechStreaming, ready: @escaping @Sendable ([Float]) -> Void) {
        queue.async { [self] in
            guard !cancelled else { return }
            self.stream = stream
            self.ready = ready
            feed()
            finishIfReady()
        }
    }

    /// Stop: what was accepted before it is converted, and nothing later is kept. `sealed` runs on the queue with the
    /// recording's length and the capture's rate.
    func seal(_ sealed: @escaping @Sendable (_ seconds: Double, _ rate: Double?) -> Void) {
        queue.async { [self] in
            guard !cancelled else { return }
            recording.seal()
            sealed(recording.seconds, recording.captureRate)
            feed()
            finishIfReady()
        }
    }

    /// Every end: the recording is dropped and nothing more is converted or fed.
    func cancel() {
        queue.async { [self] in
            cancelled = true
            recording = KeyboardRecording()
            stream = nil
            ready = nil
        }
    }

    private func feed() {
        guard let stream else { return }
        let samples = recording.takeForStream()
        if !samples.isEmpty { stream.append(samples) }
    }

    private func finishIfReady() {
        guard recording.isSealed, stream != nil, let ready else { return }
        self.ready = nil
        ready(recording.samples)
    }
}
#endif
