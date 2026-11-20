import AppKit
import DictationCore
import Foundation
import MacPlatform
import Persistence
import ScreenNotes
import SorelloUI
import SpeechEngine

/// `Sorello --self-test --screen-note [--movie <file>] <dir>` (ARCHITECTURE.md, section 11): a screen note made by the
/// app's own coordinator, recorder, renderer and engine, with marks of its own in place of the pointer. It records the
/// display under the pointer for three seconds, draws a stroke and drops a pin over it, makes the note in `<dir>` and
/// prints its summary and files. It needs Screen Recording, so it is run by hand. With `--movie`, the note is made
/// from that movie instead of a recording, which needs no permission and proves the rest. Nothing goes on the
/// clipboard. The model is the one in the app's store.
@MainActor
enum ScreenNoteSelfTest {
    static let recordFor: TimeInterval = 3
    static let limit: TimeInterval = 600

    static func run(directory: URL, movie: URL?) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task {
            let passed = await ScreenNoteSelfTestRun(directory: directory, movie: movie).run()
            exit(passed ? 0 : 1)
        }
        application.run()
        exit(1)
    }
}

@MainActor
private final class ScreenNoteSelfTestRun {
    private let directory: URL
    private let movie: URL?
    private let info = AppInfo.main()
    private let defaultsName = "sorello-self-test-\(UUID().uuidString)"

    init(directory: URL, movie: URL?) {
        self.directory = directory
        self.movie = movie
    }

    func run() async -> Bool {
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            Console.error("self-test: no settings domain")
            return false
        }
        Console.line("\(info.name) \(info.version) (\(info.build)) self-test, screen note, model \(info.modelName ?? "none")")
        let settings = SettingsStore(defaults: defaults)
        settings.screenNotes = true
        let modelStore = info.bundleIdentifier.flatMap { try? AppPaths(bundleIdentifier: $0) }?.modelsDirectory
            ?? directory.appendingPathComponent("Models", isDirectory: true)
        let info = self.info
        let model = info.pin.map { PinnedModel(pin: $0, storeDirectory: modelStore, carriedDirectory: info.modelDirectory) }
        let engine = SpeechEngine.forApp(info, model: model, store: modelStore, compute: .forThisMac(),
                                         dictionary: { _ in .empty })
        Task { await engine.prepare() }

        let clock = SystemSessionClock()
        let permission = ScreenRecordingPermission()
        var platform = ScreenNotePlatform.system()
        platform.copy = { _, sheet in Console.line("clipboard: left alone (would hold the summary and \(sheet.lastPathComponent))") }
        platform.reveal = { _ in }
        platform.pointer = ScriptedPointer()
        if let movie {
            platform.permission = GrantedScreen()
            platform.recorder = MovieRecorder(movie: movie)
            Console.line("movie: \(movie.lastPathComponent), in place of a recording")
        } else {
            guard permission.isGranted else {
                Console.line("Screen Recording is not granted to \(info.name); grant it, or pass --movie")
                return false
            }
        }
        // A movie brings its own narration. A recording here has none: this prints the summary, and what someone said
        // near the Mac must never reach a log (AGENTS.md, "Privacy rules").
        let microphone = movie != nil
        Console.line("narration: \(microphone ? "the movie's" : "none, so nothing said near the Mac is printed")")
        let store = ScreenNoteStore(directory: directory)
        let coordinator = ScreenNoteCoordinator(
            settings: settings, store: store, platform: platform, clock: clock,
            words: { file async throws(FileSpeechFailure) in try await engine.transcribeWords(file: file) },
            microphone: { (microphone, nil) }, clipboard: NoClipboardLine())

        coordinator.pressed(at: clock.now)
        guard await wait(for: { coordinator.phase == .recording || coordinator.phase == .idle }),
              coordinator.phase == .recording else {
            Console.line("recording did not start: \(coordinator.notice?.text ?? "no reason given")")
            return false
        }
        Console.line("recording")
        try? await Task.sleep(for: .seconds(ScreenNoteSelfTest.recordFor))
        coordinator.pressed(at: clock.now + 1)
        Console.line("making the note")
        guard await wait(for: { coordinator.phase == .idle }), let folder = coordinator.lastNote else {
            Console.line("no note: \(coordinator.notice?.text ?? "it did not finish")")
            Console.line("self-test FAILED")
            return false
        }
        // Names inside the directory given, never a whole path, which can name the person (AGENTS.md, "Privacy rules").
        Console.line("note: <dir>/\(folder.lastPathComponent)")
        let files = (FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []).sorted()
        for file in files { Console.line("  \(file)") }
        if let summary = try? String(contentsOf: folder.appendingPathComponent(ScreenNote.Files.summary), encoding: .utf8) {
            Console.line("summary.md:")
            Console.line(summary.replacingOccurrences(of: folder.path, with: "<dir>/\(folder.lastPathComponent)"))
        }
        Console.line("self-test passed")
        return true
    }

    private func wait(for condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(ScreenNoteSelfTest.limit)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

/// Marks of the self-test's own: a stroke across the middle of the display from 0.8 s, and a pin at 1.8 s.
@MainActor
private final class ScriptedPointer: PointerWatching {
    private var script: Task<Void, Never>?

    func start(display: NoteDisplay, startedAt: TimeInterval, handler: @escaping @MainActor (PointerEvent) -> Void) {
        let size = display.frame.size
        func at(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * size.width, y: y * size.height) }
        script = Task { @MainActor in
            func now() -> Double { ProcessInfo.processInfo.systemUptime - startedAt }
            func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            await pause(0.8)
            for step in 0...20 {
                guard !Task.isCancelled else { return }
                handler(.moved(at(0.3 + 0.3 * Double(step) / 20, 0.4 + 0.05 * sin(Double(step) / 3)), time: now(), shift: true))
                await pause(0.025)
            }
            handler(.moved(at(0.6, 0.4), time: now(), shift: false))
            await pause(0.5)
            handler(.moved(at(0.7, 0.6), time: now(), shift: true))
            handler(.buttonDown(at(0.7, 0.6), time: now(), shift: true))
            await pause(0.1)
            handler(.buttonUp(at(0.7, 0.6), time: now()))
            handler(.moved(at(0.7, 0.6), time: now(), shift: false))
        }
    }

    func stop() {
        script?.cancel()
        script = nil
    }
}

/// Nothing else uses the clipboard here.
private struct NoClipboardLine: ClipboardTurns {}

private struct GrantedScreen: ScreenPermissionChecking {
    var isGranted: Bool { true }
    func request() -> Bool { true }
    func openSettings() {}
}

/// Puts a movie where the recording would be, as if it had just been recorded.
private struct MovieRecorder: NoteRecorderStarting {
    let movie: URL

    func startRecording(display: NoteDisplay, file: URL, narrate: Bool, microphone: String?)
        async throws(ScreenRecordingFailure) -> any NoteRecordingSession {
        do {
            try FileManager.default.copyItem(at: movie, to: file)
        } catch {
            throw .failed
        }
        return CopiedMovie(startedAt: ProcessInfo.processInfo.systemUptime)
    }
}

private final class CopiedMovie: NoteRecordingSession {
    let startedAt: TimeInterval?
    init(startedAt: TimeInterval) { self.startedAt = startedAt }
    func onInterrupted(_ handler: @escaping @Sendable () -> Void) {}
    func finish() async throws(ScreenRecordingFailure) {}
    func cancel() async {}
}
