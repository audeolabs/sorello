import AppKit
import DictationCore
import Foundation
import Persistence
import SorelloUI
import SpeechEngine

/// `Sorello --self-test --transcribe <file>` (ARCHITECTURE.md, section 11): the assembled app's own composition and
/// Transcribe File's own model and binding, with the app's engine, off screen. The file is taken the way a file
/// dropped on the window is. It prints each state the window passes through and then the text the window shows, so
/// the window's way in can be checked against the `sorello` command's text for the same file, and exits 0 when the
/// window ends with text.
///
/// Like `--self-test`, it needs no permission and keeps nothing: settings, macros, the dictionary and the Run Log
/// live in a temporary directory, removed at the end, with default settings. The model is the one the app carries,
/// the one given with `--model`, or the one in the app's store; only its stable copy is kept where the app keeps it.
@MainActor
enum TranscribeSelfTest {
    /// How long the window may take to end: the model's first preparation on a Mac can take minutes, and a long file
    /// takes a while.
    static let limit: TimeInterval = 1800

    static func run(file: URL, model: URL?, forcesCPU: Bool) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Resources.registerFonts()
        Task {
            let passed = await TranscribeSelfTestRun(file: file, model: model, forcesCPU: forcesCPU).run()
            exit(passed ? 0 : 1)
        }
        application.run()
        exit(1)
    }
}

/// One run.
@MainActor
private final class TranscribeSelfTestRun {
    private let file: URL
    private let info: AppInfo
    private let forcesCPU: Bool
    private let directory: URL
    private let defaultsName = "sorello-self-test-\(UUID().uuidString)"

    init(file: URL, model: URL?, forcesCPU: Bool) {
        self.file = file
        self.forcesCPU = forcesCPU
        let bundled = AppInfo.main()
        info = model.map { bundled.withModel(at: $0) } ?? bundled
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
        Console.line("\(info.name) \(info.version) (\(info.build)) self-test, Transcribe File, model "
            + (info.modelName ?? "none"))
        Console.line("settings: defaults; nothing is pasted, kept or saved")

        let temporaryStore = directory.appendingPathComponent("Models", isDirectory: true)
        let modelStore = info.bundleIdentifier.flatMap { try? AppPaths(bundleIdentifier: $0) }?.modelsDirectory
            ?? temporaryStore
        let info = self.info
        let model = info.pin.map {
            PinnedModel(pin: $0, storeDirectory: modelStore, carriedDirectory: info.modelDirectory)
        }
        let compute = forcesCPU ? SpeechCompute.cpu : .forThisMac()
        Console.error("encoder: \(compute) (\(forcesCPU ? "forced by --cpu" : "this Mac's hardware"))")
        let clock = SystemSessionClock()
        let app = AppComposition(
            info: info, storage: AppStorage(paths: AppPaths(root: directory), defaults: defaults),
            platform: .quiet(capture: FileCapture(clock: clock), inserter: RecordingInserter(), trusted: false,
                             clock: clock),
            speech: { store in
                SpeechEngine.forApp(info, model: model, store: modelStore, compute: compute,
                                    dictionary: { store.snapshot(for: $0) })
            },
            modelFitsThisMac: model.map { $0.build != nil } ?? true, pill: NoPillShown(), levels: LevelFeed())
        app.settings.setupCompleted = true
        let models = WindowModels(app: app)
        let window = models.transcribe
        let started = ContinuousClock.now
        var lastLine = ""
        window.stateChanged = { state in
            let line = Self.describe(state, appName: info.name)
            guard line != lastLine else { return }
            lastLine = line
            Console.line("window: \(line)  [\(SelfTestTiming.seconds(ContinuousClock.now - started))]")
        }

        app.start()
        Console.line("file: \(file.lastPathComponent)")
        window.open(file: file)
        let deadline = ContinuousClock.now + .seconds(TranscribeSelfTest.limit)
        while !window.model.state.takesFiles {
            guard ContinuousClock.now < deadline else {
                Console.line("window: still busy after \(Int(TranscribeSelfTest.limit)) s")
                return await finish(app, models, passed: false)
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard case .done(_, let text) = window.model.state else {
            return await finish(app, models, passed: false)
        }
        Console.line("text:")
        Console.line(text)
        return await finish(app, models, passed: true)
    }

    private func finish(_ app: AppComposition, _ models: WindowModels, passed: Bool) async -> Bool {
        // What the window shows as the test lets go of it is not one of its states.
        models.transcribe.stateChanged = nil
        models.stop()
        await app.shutdown(limit: 1)
        Console.line(passed ? "self-test passed" : "self-test FAILED")
        return passed
    }

    /// One state as a line: what it is, the file's name, and the words the window shows with it.
    static func describe(_ state: TranscribeState, appName: String) -> String {
        switch state {
        case .empty:
            "empty"
        case .preparing(let file):
            "preparing \(file): \(TranscribeWords.preparing)"
        case .transcribing(let file, let read, let length):
            "transcribing \(file): " + (TranscribeWords.progress(read: read, length: length) ?? "length not known yet")
        case .done(let file, let text):
            "done \(file): \(text.count) characters"
        case .nothingHeard(let file):
            "nothing heard \(file): \(TranscribeWords.nothingHeard)"
        case .failed(let file, let reason):
            "failed \(file): \(TranscribeWords.reason(reason, appName: appName))"
        }
    }
}

/// No pill: this self-test dictates nothing.
@MainActor
private final class NoPillShown: PillPresenting {
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}
    var onNoticeAction: (UInt64, String) -> Void = { _, _ in }
    func show(_ display: PillDisplay) {}
}

/// Durations as the self-tests print them.
nonisolated enum SelfTestTiming {
    static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.3f s", value)
    }
}
