import AppKit
import DictationCore
import Persistence
import SorelloUI
import SpeechEngine

/// The menu-bar app (ARCHITECTURE.md, section 8, "Windows"): a status item with its menu, the main window and setup,
/// one running instance, and a Dock icon only while one of its windows is open. It builds the composition at launch,
/// starts the model's preparation, takes permission changes made in System Settings without a relaunch, and lets go
/// of the microphone and any stream before it quits, whether by Quit, `osascript … quit` or SIGTERM.
@MainActor
final class AppShell: NSObject, NSApplicationDelegate {
    private let showsSetup: Bool
    private var app: AppComposition?
    private var models: WindowModels?
    private var statusItem: StatusItemController?
    private let windows = WindowPresenter(dock: SystemDock())
    private var overlay: PillOverlayController?
    private var terminationSignal: (any DispatchSourceSignal)?
    /// The shutdown, once something asked the app to quit.
    private var shutdown: Task<Void, Never>?
    /// The shutdown has finished: the next request to terminate goes ahead at once.
    private var shutDown = false
    /// AppKit is waiting for `reply(toApplicationShouldTerminate:)`.
    private var replyPending = false

    private init(showsSetup: Bool) {
        self.showsSetup = showsSetup
    }

    /// Runs the app until it quits.
    static func run(showsSetup: Bool) -> Never {
        let application = NSApplication.shared
        let shell = AppShell(showsSetup: showsSetup)
        application.delegate = shell
        // A copy run outside its bundle has no LSUIElement; the app starts as a menu-bar app either way, and is in the
        // Dock only while one of its windows is open.
        application.setActivationPolicy(.accessory)
        application.run()
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = AppInfo.main()
        guard let identifier = info.bundleIdentifier, let paths = try? AppPaths(bundleIdentifier: identifier) else {
            Console.error("Sorello runs from its app bundle: build it with `make app`, then open the app.")
            exit(64)
        }
        // One running instance: a second launch brings the first one's window forward and leaves.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let running = others.first {
            running.activate()
            exit(0)
        }

        Resources.registerFonts()
        NSApp.mainMenu = MainMenu.make(appName: info.name, target: self)
        let platform = AppPlatform.system()
        let levels = LevelFeed()
        let clock = platform.clock
        let overlay = PillOverlayController(levels: levels, clock: { clock.now })
        self.overlay = overlay
        // The engine and the download are made together, from the same pinned model, so they mean the same build.
        let model = info.pin.map {
            PinnedModel(pin: $0, storeDirectory: paths.modelsDirectory, carriedDirectory: info.modelDirectory)
        }
        let app = AppComposition(
            info: info, storage: AppStorage(paths: paths, defaults: .standard), platform: platform,
            speech: { store in
                SpeechEngine.forApp(info, model: model, store: paths.modelsDirectory, compute: .forThisMac(),
                                    dictionary: { store.snapshot(for: $0) })
            },
            download: model.map { PinnedDownload(model: $0, version: info.version) },
            pill: overlay, levels: levels)
        self.app = app
        let models = WindowModels(app: app)
        self.models = models
        app.navigation = Navigation(
            openMain: { [weak self] section in self?.showMain(at: section) },
            openSetup: { [weak self] in self?.showSetup() },
            closeSetup: { [weak self] in self?.windows.closeSetup() },
            bringBack: { [weak self] window in self?.windows.bringBack(window) },
            showNotice: { [weak self] title, files in self?.windows.showNotice(title: title, files: files) },
            alert: { title, message in
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = message
                NSApp.activate()
                alert.runModal()
            },
            quit: { [weak self] in self?.quit(nil) })
        statusItem = StatusItemController(model: models.menu, appName: info.name)
        app.start()
        watchActivation(app)
        catchTermination()
        if showsSetup && models.setupIsNeeded { showSetup() }
    }

    /// Clicking the Dock icon, or opening the app again from Finder, Spotlight or `open`, brings the open windows
    /// forward, minimised ones too, and opens the main window only when none is open. The presenter does all of it,
    /// so AppKit is told to do nothing more.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let models, let app else { return false }
        windows.reopen(main: models.main, title: app.info.name)
        return false
    }

    /// A quit the system asks for (an Apple event: `osascript … quit`, logging out) waits for the shutdown. AppKit
    /// waits in a loop of its own that still runs the main queue, so the shutdown can finish inside it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shutDown || app == nil { return .terminateNow }
        replyPending = true
        let shutdown = shutDownOnce()
        Task {
            await shutdown.value
            finishedShuttingDown()
        }
        return .terminateLater
    }

    /// A quit from inside the app (Quit, ⌘Q, SIGTERM) shuts down first and only then terminates, so AppKit never
    /// waits for work queued behind the very call that asked it to quit.
    @objc func quit(_ sender: Any?) {
        let shutdown = shutDownOnce()
        Task {
            await shutdown.value
            finishedShuttingDown()
        }
    }

    /// Lets go of everything, once, however many ways the app was asked to quit.
    private func shutDownOnce() -> Task<Void, Never> {
        if let shutdown { return shutdown }
        models?.stop()
        statusItem?.close()
        let app = self.app
        let task = Task<Void, Never> {
            if let app { await app.shutdown() }
        }
        shutdown = task
        return task
    }

    private func finishedShuttingDown() {
        shutDown = true
        if replyPending {
            replyPending = false
            NSApp.reply(toApplicationShouldTerminate: true)
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Windows

    private func showMain(at section: MainSection?) {
        guard let models, let app else { return }
        windows.showMain(models.main, section: section, title: app.info.name)
    }

    private func showSetup() {
        guard let models, let app else { return }
        // The steps are fixed as setup opens: once the model's step is there, it stays for that setup.
        if !windows.isOpen(.setup) { models.setup.steps = models.setupSteps }
        models.setup.step = models.setupStartStep
        windows.showSetup(models.setup, title: app.info.name)
    }

    // MARK: - Menu commands

    @objc func showAbout(_ sender: Any?) { showMain(at: .about) }

    @objc func showSettings(_ sender: Any?) { showMain(at: nil) }

    // MARK: - The system

    /// A permission granted in System Settings takes effect when the user comes back to Sorello.
    private func watchActivation(_ app: AppComposition) {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { app.becameActive() }
        }
    }

    /// SIGTERM quits the way Quit does, so the microphone, the streams and a clipboard waiting to be put back are
    /// all handled before the process ends.
    private func catchTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.quit(nil) }
        }
        source.resume()
        terminationSignal = source
    }
}
