import AppKit
import DesignCore
import DictationCore
import Foundation
import Persistence
import SorelloUI
import SpeechEngine

/// `Sorello --self-test <file.wav>…` (ARCHITECTURE.md, section 11): the assembled app's own composition and session,
/// with each file in place of the microphone and a recorder in place of the paste. Each file is one dictation,
/// started and ended by a synthetic Hold to Talk through the same relay the keyboard uses; the real pill shows it.
/// The last file is then dictated once more hands-free, started by a double tap and stopped by one more tap.
/// It prints what would have been inserted and how long each step took, and exits 0 when every dictation produced
/// text. It says on standard error where the encoder runs; `--cpu` forces Core ML's CPU kernels, to prove on any Mac
/// the fallback a Mac without a Neural Engine uses.
///
/// It needs no permission and keeps nothing: settings, macros, the dictionary and the Run Log live in a temporary
/// directory, removed at the end, with default settings except that "press enter" is on. Only the model's stable
/// copy is kept where the app keeps it, so the app's own first launch afterwards is warm.
@MainActor
enum SelfTest {
    /// How long the model may take to prepare. The first preparation on a Mac with a Neural Engine compiles the
    /// model for it, which can take minutes. The CPU fallback compiles nothing, but nobody has timed it on an Intel
    /// processor, so it gets the same allowance.
    static let preparationLimit: TimeInterval = 600
    /// How long a dictation may take to come back after its audio ends.
    static let completionLimit: TimeInterval = 60

    /// `forcesCPU` runs the encoder on Core ML's CPU kernels whatever the hardware offers, to prove the fallback.
    static func run(files: [URL], model: URL?, forcesCPU: Bool) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Resources.registerFonts()
        Task {
            let passed = await SelfTestRun(files: files, model: model, forcesCPU: forcesCPU).run()
            exit(passed ? 0 : 1)
        }
        application.run()
        exit(1)
    }
}

/// One self-test.
@MainActor
private final class SelfTestRun {
    private let files: [URL]
    private let info: AppInfo
    private let forcesCPU: Bool
    private let clock = SystemSessionClock()
    private let capture: FileCapture
    private let inserter = RecordingInserter()
    private let pill: RecordingPill
    private let directory: URL
    private let defaultsName = "sorello-self-test-\(UUID().uuidString)"
    private var completions: [DictationCompletion] = []

    init(files: [URL], model: URL?, forcesCPU: Bool) {
        self.files = files
        self.forcesCPU = forcesCPU
        let bundled = AppInfo.main()
        info = model.map { bundled.withModel(at: $0) } ?? bundled
        capture = FileCapture(clock: clock)
        let levels = LevelFeed()
        let clock = self.clock
        pill = RecordingPill(PillOverlayController(levels: levels, clock: { clock.now }), levels: levels)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorello-self-test-\(UUID().uuidString)", isDirectory: true)
    }

    func run() async -> Bool {
        defer {
            UserDefaults.standard.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            Console.error("self-test: no settings domain")
            return false
        }
        Console.line("\(info.name) \(info.version) (\(info.build)) self-test, model \(info.modelName ?? "none")")
        Console.line("settings: defaults, with \u{201C}press enter\u{201D} on; nothing is pasted")

        // The model's stable copy goes where the app keeps it, when there is an app; otherwise it is temporary too.
        let modelStore = info.bundleIdentifier.flatMap { try? AppPaths(bundleIdentifier: $0) }?.modelsDirectory
            ?? directory.appendingPathComponent("Models", isDirectory: true)
        let info = self.info
        let compute = forcesCPU ? SpeechCompute.cpu : .forThisMac()
        Console.error("encoder: \(compute) (\(forcesCPU ? "forced by --cpu" : "this Mac's hardware"))")
        let app = AppComposition(
            info: info, storage: AppStorage(paths: AppPaths(root: directory), defaults: defaults),
            platform: .quiet(capture: capture, inserter: inserter, trusted: false, clock: clock),
            speech: { store in
                SpeechEngine.forApp(info, store: modelStore, compute: compute, dictionary: { store.snapshot(for: $0) })
            },
            pill: pill, levels: pill.levels)
        app.settings.pressEnterCommand = true
        app.settings.setupCompleted = true
        let forward = app.runtime.onCompletion
        app.runtime.onCompletion = { [weak self] completion in
            forward?(completion)
            self?.completions.append(completion)
        }

        let preparing = ContinuousClock.now
        app.start()
        guard await wait(SelfTest.preparationLimit, until: { app.runtime.state.engine != .preparing }) else {
            Console.line("model: still preparing after \(Int(SelfTest.preparationLimit)) s")
            return await finish(app, passed: false)
        }
        guard app.runtime.state.engine == .ready else {
            Console.line("model: \(String(describing: app.runtime.state.engine))")
            return await finish(app, passed: false)
        }
        Console.line("model: ready in \(Self.seconds(ContinuousClock.now - preparing))")

        var passed = true
        for file in files {
            passed = await dictate(file, through: app) && passed
        }
        if let last = files.last {
            passed = await dictateHandsFree(last, through: app) && passed
        }
        let expected = inserter.inserted.count
        _ = await wait(10, until: { app.history.entries.count >= expected })
        Console.line("run log: \(app.history.entries.count) of \(expected) dictations recorded")
        Console.line("pill: \(pill.summary)")
        if app.history.entries.count != expected { passed = false }
        return await finish(app, passed: passed)
    }

    /// One file as one dictation: hold, speak at the recording's own pace, release, and wait for the text.
    private func dictate(_ file: URL, through app: AppComposition) async -> Bool {
        let name = file.lastPathComponent
        guard let samples = read(file) else { return false }
        capture.queue(samples)
        let before = completions.count, insertedBefore = inserter.inserted.count
        let pressed = ContinuousClock.now
        app.relay.handle(.holdPressed, at: clock.now)
        guard await wait(5, until: { app.runtime.state.capture.live != nil && self.isRecording(app) }) else {
            Console.line("\(name): the recording did not start")
            return false
        }
        await capture.waitUntilPlayed()
        app.relay.handle(.holdReleased(.keyUp), at: clock.now)
        let released = ContinuousClock.now
        guard await wait(SelfTest.completionLimit, until: { self.completions.count > before }),
              let completion = completions.last else {
            Console.line("\(name): no result within \(Int(SelfTest.completionLimit)) s of the release")
            return false
        }
        return await report(name, samples: samples, completion: completion, insertedBefore: insertedBefore,
                            pressed: pressed, released: released)
    }

    /// The file once more as a hands-free dictation (rule 5): tap Hold to Talk, press it again and let go at once,
    /// let the recording play with no key held, then tap once more to stop it, and wait for the text.
    private func dictateHandsFree(_ file: URL, through app: AppComposition) async -> Bool {
        let name = "\(file.lastPathComponent), hands-free"
        guard let samples = read(file) else { return false }
        // The tap records a little silence of its own, so the file is left for the dictation the double tap starts.
        // Its capture has started, and taken the silence, before the tap is released.
        capture.queue([Float](repeating: 0, count: Int(AudioFormat.sampleRate) / 10))
        app.relay.handle(.holdPressed, at: clock.now)
        guard await wait(SessionTiming.tapHold * 0.8, until: { self.isRecording(app) }) else {
            Console.line("\(name): the tap's recording did not start in time")
            return false
        }
        app.relay.handle(.holdReleased(.keyUp), at: clock.now)
        guard app.runtime.state.capture == .idle, app.runtime.state.tap != nil else {
            Console.line("\(name): the tap did not arm the double tap")
            return false
        }
        capture.queue(samples)
        let insertedBefore = inserter.inserted.count
        // The second press comes as a person's would, a moment after the tap and well inside its window, and is let
        // go a moment later.
        try? await Task.sleep(for: .seconds(SessionTiming.tapWindow / 2))
        let pressed = ContinuousClock.now
        app.relay.handle(.holdPressed, at: clock.now)
        let live = app.runtime.state.capture.live
        try? await Task.sleep(for: .seconds(SessionTiming.tapHold / 2))
        app.relay.handle(.holdReleased(.keyUp), at: clock.now)
        guard let live, live.mode == .toggle, live.style == .plain else {
            Console.line("\(name): the double tap did not start a hands-free dictation")
            return false
        }
        let id = live.id
        guard await wait(5, until: { self.isRecording(app) }) else {
            Console.line("\(name): the recording did not start")
            return false
        }
        await capture.waitUntilPlayed()
        guard app.runtime.state.capture.live?.id == id else {
            Console.line("\(name): the recording stopped before the tap that ends it")
            return false
        }
        app.relay.handle(.holdPressed, at: clock.now)
        try? await Task.sleep(for: .seconds(SessionTiming.tapHold / 2))
        guard app.runtime.state.capture.live?.id == id else {
            Console.line("\(name): the recording stopped at the press, not the release")
            return false
        }
        app.relay.handle(.holdReleased(.keyUp), at: clock.now)
        let released = ContinuousClock.now
        guard await wait(SelfTest.completionLimit, until: { self.completions.contains { $0.id == id } }),
              let completion = completions.last(where: { $0.id == id }) else {
            Console.line("\(name): no result within \(Int(SelfTest.completionLimit)) s of the tap that ends it")
            return false
        }
        return await report(name, samples: samples, completion: completion, insertedBefore: insertedBefore,
                            pressed: pressed, released: released)
    }

    private func read(_ file: URL) -> [Float]? {
        do {
            return try AudioFileReader.samples(contentsOf: file)
        } catch {
            Console.line("\(file.lastPathComponent): could not be read")
            return nil
        }
    }

    /// Prints how one dictation went and says whether its text was inserted. `released` is when the key that
    /// ended it came up.
    private func report(_ name: String, samples: [Float], completion: DictationCompletion, insertedBefore: Int,
                        pressed: ContinuousClock.Instant, released: ContinuousClock.Instant) async -> Bool {
        let duration = Double(samples.count) / AudioFormat.sampleRate
        let done = ContinuousClock.now
        let timing = String(format: "%.1f s of audio, recorded for %@, ", duration, Self.seconds(released - pressed))
            + "text ready \(Self.seconds(done - released)) after the release"
        guard case .insertion(.inserted) = completion.ending, inserter.inserted.count > insertedBefore,
              let insertion = inserter.inserted.last else {
            Console.line("\(name): \(timing); ended \(String(describing: completion.ending))")
            return false
        }
        Console.line("\(name): \(timing)")
        Console.line("  heard:  \(completion.processed?.heard ?? "")")
        Console.line("  insert: \(insertion.text)")
        Console.line("  press Return: \(insertion.pressEnter ? "yes" : "no")")
        // Let the pill go back up before the next dictation.
        _ = await wait(2, until: { self.pill.current == .hidden })
        return true
    }

    private func isRecording(_ app: AppComposition) -> Bool {
        if case .recording = app.runtime.state.capture { return true }
        return false
    }

    private func finish(_ app: AppComposition, passed: Bool) async -> Bool {
        await app.shutdown()
        Console.line(passed ? "self-test passed" : "self-test FAILED")
        return passed
    }

    /// Waits until `condition` holds, at most `seconds`; false when it never did.
    private func wait(_ seconds: TimeInterval, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.3f s", value)
    }
}

/// The real pill, and a note of each state it was shown and where, to report that it was on the screen and in its
/// place under the housing.
@MainActor
private final class RecordingPill: PillPresenting {
    private let overlay: PillOverlayController
    let levels: LevelFeed
    private var states: [String] = []
    private var frames: Set<String> = []
    /// Where the listening pill's body was, in the screen's points.
    private var listening: CGRect?
    private(set) var current: PillDisplay = .hidden

    init(_ overlay: PillOverlayController, levels: LevelFeed) {
        self.overlay = overlay
        self.levels = levels
    }

    var onStop: () -> Void {
        get { overlay.onStop }
        set { overlay.onStop = newValue }
    }
    var onCancel: () -> Void {
        get { overlay.onCancel }
        set { overlay.onCancel = newValue }
    }
    var onNoticeAction: (UInt64, String) -> Void {
        get { overlay.onNoticeAction }
        set { overlay.onNoticeAction = newValue }
    }

    func show(_ display: PillDisplay) {
        current = display
        overlay.show(display)
        let name: String = switch display {
        case .hidden: "hidden"
        case .listening: "listening"
        case .waiting(.transcribing): "transcribing"
        case .waiting(.preparingModel): "preparing"
        case .notice: "notice"
        }
        if states.last != name { states.append(name) }
        if case .listening = display { listening = overlay.layout?.body.frame }
        if let frame = overlay.drawingFrame {
            frames.insert("\(Int(frame.width))x\(Int(frame.height)) at (\(Int(frame.minX)), \(Int(frame.minY)))")
        }
    }

    var summary: String {
        let housing = overlay.topology.map { $0.housing.map { "x \($0.minX) to \($0.maxX)" } ?? "none" } ?? "unknown"
        let body = listening.map { String(format: "%gx%g at (%g, %g)", $0.width, $0.height, $0.minX, $0.minY) }
            ?? "unknown"
        return states.joined(separator: " → ") + "; housing \(housing); listening body \(body); drawn in "
            + frames.sorted().joined(separator: ", ")
    }
}
