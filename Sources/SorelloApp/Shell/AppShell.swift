import AppKit
import DictationCore
import Persistence
import SorelloUI
import SpeechEngine

/// The menu-bar app (ARCHITECTURE.md, section 8, "Windows"): a status item with its menu, the main window, setup and
/// Transcribe File, one running instance, and a Dock icon only while one of its windows is open. It builds the
/// composition at launch, starts the model's preparation, takes permission changes made in System Settings without a
/// relaunch, opens Transcribe File with an audio or video file opened with Sorello from the Finder or dropped on its
/// Dock icon, and lets go of the microphone and any stream before it quits, whether by Quit, `osascript … quit` or
/// SIGTERM.
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
    /// Files opened with Sorello before it had finished launching, as when opening one is what launched it.
    private var filesToOpen = OpenedFiles()

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
        // No window of Sorello's has tabs, so the Window menu offers none.
        NSWindow.allowsAutomaticWindowTabbing = false
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
        let menus = MainMenu.make(appName: info.name, target: self)
        NSApp.mainMenu = menus.bar
        NSApp.windowsMenu = menus.window
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
            // Only a build with an update feed has an updater; it starts with the app.
            updater: Updates.updater(for: info) { SparkleUpdater(info: $0) },
            modelFitsThisMac: model.map { $0.build != nil } ?? true, pill: overlay, levels: levels)
        self.app = app
        let models = WindowModels(app: app)
        self.models = models
        app.navigation = Navigation(
            openMain: { [weak self] section in self?.showMain(at: section) },
            openSetup: { [weak self] in self?.showSetup() },
            closeSetup: { [weak self] in self?.windows.closeSetup() },
            showTranscribe: { [weak self] in self?.showTranscribe() },
            chooseAudioFile: { [weak self] chosen in self?.panels.chooseFile(chosen) },
            saveText: { [weak self] text, name in self?.panels.save(text, name: name) },
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
        windows.onClose = { [weak models] window in
            if window == .transcribe { models?.transcribe.windowClosed() }
        }
        statusItem = StatusItemController(model: models.menu, appName: info.name)
        app.start()
        watchActivation(app)
        watchFrontApps()
        catchTermination()
        if showsSetup && models.setupIsNeeded { showSetup() }
        // A file whose opening launched the app, after the launch the app always has, setup included.
        if let file = filesToOpen.launched() { models.transcribe.open(file: file) }
    }

    /// An audio or video file opened with Sorello from the Finder, dropped on its Dock icon, or given to `open`: the
    /// first one goes to Transcribe File, which takes one file at a time. One that arrives before the launch has
    /// finished waits for it.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let file = filesToOpen.opened(urls) else { return }
        models?.transcribe.open(file: file)
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

    private func showTranscribe() {
        guard let models else { return }
        windows.showTranscribe(models.transcribe.model, title: TranscribeWords.title)
    }

    /// The open and save panels, as sheets on Transcribe File.
    private var panels: TranscribePanels {
        TranscribePanels(window: { [weak self] in self?.windows.window(.transcribe) })
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

    /// Tells the presenter which app comes to the front, starting with the one in front at launch, so that when
    /// Sorello's last window closes the front can go back to the app the user was in before.
    private func watchFrontApps() {
        let workspace = NSWorkspace.shared
        if let front = workspace.frontmostApplication { windows.appCameToFront(front) }
        workspace.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                 queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app { self?.windows.appCameToFront(app) }
            }
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

/// Files opened with Sorello, held until the app has finished launching (ARCHITECTURE.md, section 8, "Windows").
/// AppKit hands over the file whose opening launched the app before the launch has finished, when there is no window
/// to show it in yet; the app's ordinary launch runs first and the file goes to Transcribe File after it. Only the
/// first file of each opening counts, since the window takes one file at a time.
nonisolated struct OpenedFiles {
    private var waiting: URL?
    private var hasLaunched = false

    /// Hears an opening. Returns the file to show now, or nil when there is none or it must wait for the launch.
    mutating func opened(_ urls: [URL]) -> URL? {
        guard let file = urls.first(where: \.isFileURL) else { return nil }
        guard hasLaunched else {
            if waiting == nil { waiting = file }
            return nil
        }
        return file
    }

    /// The launch has finished. Returns the file that was waiting for it, if any; later openings go straight through.
    mutating func launched() -> URL? {
        hasLaunched = true
        defer { waiting = nil }
        return waiting
    }
}
