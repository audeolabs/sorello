import AppKit
import DesignCore
import DictationCore
import DictionaryKit
import Foundation
import MacPlatform
import Persistence
import SorelloUI
import SpeechEngine
import SwiftUI

/// `Sorello --snapshots <dir>`: the menu-bar item, every main window section and every setup step as the app draws
/// them, wired to real stores, rendered to PNG files, and the menu-bar item's menu as the app builds it, listed as
/// text in `app-menu.txt` (the system draws the menu, so there is no picture of it). SorelloUI's own snapshots draw
/// invented models; these draw the models the app builds, so what is reviewed is what ships. It also builds setup and
/// the main window as the app shows them, never on screen, and fails if either loses its chrome's size or minimum.
///
/// The stores are real and live in a temporary directory, filled with invented words, macros and Run Log entries,
/// and one dictation is run through the session so the menu's Copy Last Dictation is available. The engine and the
/// platform are stand-ins that report ready and granted, so the pictures show the app as it is when all is well.
@MainActor
enum WindowSnapshots {
    static func run(into directory: URL) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Resources.registerFonts()
        Task {
            let passed = await render(into: directory)
            exit(passed ? 0 : 1)
        }
        application.run()
        exit(1)
    }

    private static func render(into output: URL) async -> Bool {
        let data = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorello-snapshots-\(UUID().uuidString)", isDirectory: true)
        let defaultsName = "sorello-snapshots-\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: data)
        }
        guard let defaults = UserDefaults(suiteName: defaultsName) else { return false }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            Console.error("snapshots: cannot write to the output directory")
            return false
        }

        let clock = SystemSessionClock()
        let capture = FileCapture(clock: clock)
        let microphones = [AudioInputDevice(id: "built-in", name: "MacBook Pro Microphone", isDefault: true),
                           AudioInputDevice(id: "studio", name: "Studio Headset", isDefault: false)]
        let app = AppComposition(
            info: AppInfo.main(), storage: AppStorage(paths: AppPaths(root: data), defaults: defaults),
            platform: .quiet(capture: capture, inserter: RecordingInserter(), trusted: true,
                             microphones: microphones, clock: clock),
            speech: { _ in ReadySpeech(transcript: "Meet Okonkwo by the north gate at nine.") },
            pill: NoPill(), levels: LevelFeed())
        let models = WindowModels(app: app)
        await fill(app, capture: capture, clock: clock)
        // Let the models follow what changed.
        try? await Task.sleep(for: .milliseconds(200))

        var scenes: [SnapshotScene] = [
            SnapshotScene(name: "app-menu-bar", size: CGSize(width: 220, height: 24 * 2 + 12), background: Palette.screen) {
                MenuBarStrip()
            },
        ]
        let size = WindowChrome.Kind.main.defaultSize
        for section in MainSection.allCases {
            scenes.append(SnapshotScene(name: "app-main-\(slug(section))", size: size) {
                models.main.section = section
                return NSHostingView(rootView: MainWindowView(model: models.main)
                    .environment(\.frozenAnimationPhase, ScreenSnapshots.frozenPhase)
                    .frame(width: size.width, height: size.height).preferredColorScheme(.dark))
            })
        }
        for step in SetupStep.allCases {
            scenes.append(SnapshotScene(name: "app-setup-\(slug(step))", size: WindowChrome.Kind.setup.defaultSize) {
                models.setup.step = step
                return NSHostingView(rootView: SetupView(model: models.setup)
                    .environment(\.frozenAnimationPhase, ScreenSnapshots.frozenPhase)
                    .frame(width: WindowChrome.Kind.setup.defaultSize.width,
                           height: WindowChrome.Kind.setup.defaultSize.height)
                    .preferredColorScheme(.dark))
            })
        }
        scenes += CardSnapshots.scenes
        var passed = true
        let menu = StatusMenuController(model: models.menu)
        if (try? menu.text.write(to: output.appendingPathComponent("app-menu.txt"), atomically: true,
                                 encoding: .utf8)) != nil {
            Console.line("app-menu.txt")
        } else {
            Console.line("FAILED app-menu.txt")
            passed = false
        }
        for scene in scenes {
            guard let png = SnapshotRenderer.png(of: scene),
                  (try? png.write(to: output.appendingPathComponent(scene.name + ".png"))) != nil else {
                Console.line("FAILED \(scene.name)")
                passed = false
                continue
            }
            Console.line(scene.name)
        }
        // After the pictures, so stepping the real windows cannot change one.
        if await !checkWindowSizes(models, title: app.info.name) { passed = false }
        models.stop()
        await app.shutdown(limit: 1)
        return passed
    }

    /// Builds setup and the main window with the functions the app shows them with, never on screen, takes setup
    /// through every step and the main window through every section, and prints a line naming the window wherever
    /// one does not have its chrome's size and minimum (ARCHITECTURE.md, section 8, "Windows").
    private static func checkWindowSizes(_ models: WindowModels, title: String) async -> Bool {
        var failures: [String] = []
        let setup = WindowPresenter.setupWindow(models.setup, title: title)
        for step in SetupStep.allCases {
            models.setup.step = step
            if let failure = await sizeFailure(of: setup, .setup) {
                failures.append("window-setup at \(slug(step)): \(failure)")
            }
        }
        setup.close()
        let main = WindowPresenter.mainWindow(models.main, title: title)
        for section in MainSection.allCases {
            models.main.section = section
            if let failure = await sizeFailure(of: main, .main) {
                failures.append("window-main at \(slug(section)): \(failure)")
            }
        }
        main.close()
        guard failures.isEmpty else {
            failures.forEach { Console.line("FAILED \($0)") }
            return false
        }
        Console.line("window-setup \(describe(.setup)) at every step")
        Console.line("window-main \(describe(.main)) at every section")
        return true
    }

    /// What is wrong with `window`'s size once the run loop has turned, when the window's content may have asked it
    /// for another; nil when it has the size and minimum its chrome gives it.
    private static func sizeFailure(of window: NSWindow, _ kind: WindowChrome.Kind) async -> String? {
        try? await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        let size = window.contentRect(forFrameRect: window.frame).size
        guard size != kind.defaultSize || window.contentMinSize != kind.minimumSize else { return nil }
        return "\(points(size)), minimum \(points(window.contentMinSize)), not \(describe(kind))"
    }

    private static func describe(_ kind: WindowChrome.Kind) -> String {
        "\(points(kind.defaultSize)), minimum \(points(kind.minimumSize))"
    }

    private static func points(_ size: CGSize) -> String { "\(Int(size.width)) x \(Int(size.height))" }

    /// Invented words, macros and dictations, put in through the stores the way the windows and the session do.
    private static func fill(_ app: AppComposition, capture: FileCapture, clock: SystemSessionClock) async {
        app.start()
        app.settings.tapToToggleShortcut = .key(code: 49, modifiers: [.control, .option])
        app.settings.setupCompleted = true
        _ = try? app.macros.add(command: "sign off", text: "Warm regards,\nAda")
        _ = try? app.macros.add(command: "my address", text: "14 Larkspur Lane, Northwind")
        if app.dictionary.canEdit, let notes = DictionaryApp(id: "com.example.fieldnotes", name: "Field Notes") {
            try? app.dictionary.register(notes)
            try? app.dictionary.save(text: "Okonkwo", strength: 2, apps: [], replacing: nil)
            try? app.dictionary.save(text: "Vexlimer", strength: 1.41, apps: [notes.id], replacing: nil)
            try? app.dictionary.save(text: "Quillon Bay", strength: 1, apps: [], replacing: nil)
            try? app.dictionary.ignore(DictionaryKey("okay quo"))
        }
        let tone = (0..<Int(AudioFormat.sampleRate * 2)).map { Float(sin(Double($0) * 0.04) * 0.15) }
        let now = Date()
        for (offset, heard, text, outcome) in [
            (5400.0, "order twenty three crates of pears", "Order 23 crates of pears.", DictationOutcome.inserted),
            (1800.0, "send it press enter", "Send it.", .inserted),
            (600.0, "the meeting moved to thursday", "The meeting moved to Thursday.", .leftOnClipboard),
        ] {
            await app.history.record(HistoryDraft(date: now.addingTimeInterval(-offset), heard: heard, text: text,
                                                  outcome: outcome, samples: tone))
        }
        // One dictation through the session, so the menu's Copy Last Dictation is available.
        guard await waitFor({ app.runtime.state.engine == .ready }) else { return }
        capture.queue(tone)
        app.relay.handle(.holdPressed, at: clock.now)
        guard await waitFor({ if case .recording = app.runtime.state.capture { true } else { false } }) else { return }
        await capture.waitUntilPlayed()
        app.relay.handle(.holdReleased(.keyUp), at: clock.now)
        _ = await waitFor({ app.runtime.state.lastText != nil && app.history.entries.count == 4 })
    }

    private static func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private static func slug(_ section: MainSection) -> String {
        switch section {
        case .general: "general"
        case .shortcuts: "shortcuts"
        case .dictionary: "dictionary"
        case .macros: "macros"
        case .runLog: "runlog"
        case .about: "about"
        }
    }

    private static func slug(_ step: SetupStep) -> String {
        switch step {
        case .welcome: "welcome"
        case .microphone: "microphone"
        case .accessibility: "accessibility"
        case .shortcut: "shortcut"
        case .test: "test"
        }
    }
}

/// The status item as it sits in a dark and a light menu bar: the system tints the template image.
private struct MenuBarStrip: View {
    var body: some View {
        VStack(spacing: 4) {
            bar(background: Color(white: 0.12), ink: .white)
            bar(background: Color(white: 0.93), ink: .black)
        }
        .padding(4)
    }

    private func bar(background: Color, ink: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "wifi").foregroundStyle(ink)
            Image(nsImage: SorelloMarkImages.menuBarIcon()).renderingMode(.template).foregroundStyle(ink)
            Image(systemName: "battery.75percent").foregroundStyle(ink)
            Text("9:41").font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(background)
    }
}

/// An engine that is ready on the Neural Engine and hears one sentence.
nonisolated private struct ReadySpeech: AppSpeech {
    let transcript: String
    let compute = SpeechCompute.neuralEngine

    struct Stream: SpeechStreaming {
        let transcript: String
        func append(_ samples: [Float]) {}
        func finish() async throws -> SpeechResult { SpeechResult(text: transcript) }
        func cancel() {}
    }

    func prepare() async {}
    func readiness() -> AsyncStream<EngineReadiness> { AsyncStream { $0.yield(.ready) } }
    func openStream(_ options: SpeechStreamOptions) -> any SpeechStreaming { Stream(transcript: transcript) }
    func transcribe(_ samples: [Float], appBundleID: String?) async throws(SpeechFailure) -> String { transcript }
    func correctionCheck(typed: String, edited: String, correctionID: UInt64, ignore: Set<DictionaryKey>,
                         isLast: Bool) -> @Sendable () async -> DictionarySuggestion? { { nil } }
    func releaseCorrection(_ correctionID: UInt64) {}
    func discardCorrection() {}
}

/// No pill: the snapshots draw windows only.
@MainActor
private final class NoPill: PillPresenting {
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}
    var onNoticeAction: (UInt64, String) -> Void = { _, _ in }
    func show(_ display: PillDisplay) {}
}
