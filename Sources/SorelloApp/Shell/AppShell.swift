import AppKit
import DictationCore
import Persistence
import SorelloUI
import SpeechEngine

/// The menu-bar app (ARCHITECTURE.md, section 8, "Windows"): no Dock icon, a status item with the menu panel, the main
/// window and setup, one running instance. It builds the composition at launch, starts the model's preparation,
/// takes permission changes made in System Settings without a relaunch, and lets go of the microphone and any stream
/// before it quits, whether by Quit, `osascript … quit` or SIGTERM.
@MainActor
final class AppShell: NSObject, NSApplicationDelegate {
    private let showsSetup: Bool
    private var app: AppComposition?
    private var models: WindowModels?
    private var statusItem: StatusItemController?
    private var windows = WindowPresenter()
    private var overlay: PillOverlayController?
    private var terminationSignal: (any DispatchSourceSignal)?
    private var quitting = false

    private init(showsSetup: Bool) {
        self.showsSetup = showsSetup
    }

    /// Runs the app until it quits.
    static func run(showsSetup: Bool) -> Never {
        let application = NSApplication.shared
        let shell = AppShell(showsSetup: showsSetup)
        application.delegate = shell
        // A copy run outside its bundle has no LSUIElement; the app is a menu-bar app either way.
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
        let app = AppComposition(
            info: info, storage: AppStorage(paths: paths, defaults: .standard), platform: platform,
            speech: { store in
                SpeechEngine(modelDirectory: info.modelDirectory, storeDirectory: paths.modelsDirectory,
                             dictionary: { store.snapshot(for: $0) })
            },
            pill: overlay, levels: levels)
        self.app = app
        let models = WindowModels(app: app)
        self.models = models
        app.navigation = Navigation(
            openMain: { [weak self] section in self?.showMain(at: section) },
            openSetup: { [weak self] in self?.showSetup() },
            closeSetup: { [weak self] in self?.windows.closeSetup() },
            showNotice: { [weak self] title, files in self?.windows.showNotice(title: title, files: files) },
            alert: { title, message in
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = message
                NSApp.activate()
                alert.runModal()
            },
            quit: { NSApp.terminate(nil) })
        statusItem = StatusItemController(model: models.menu, appName: info.name)
        app.start()
        watchActivation(app)
        catchTermination()
        if showsSetup && models.setupIsNeeded { showSetup() }
    }

    /// Opening the app again (from Finder, Spotlight or `open`) shows the main window, since there is no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain(at: nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A second request while the first is being handled (Quit, then SIGTERM) waits for the first.
        guard !quitting else { return .terminateCancel }
        guard let app else { return .terminateNow }
        quitting = true
        models?.stop()
        statusItem?.close()
        Task {
            await app.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Windows

    private func showMain(at section: MainSection?) {
        guard let models, let app else { return }
        statusItem?.close()
        windows.showMain(models.main, section: section, title: app.info.name)
    }

    private func showSetup() {
        guard let models, let app else { return }
        statusItem?.close()
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
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        source.resume()
        terminationSignal = source
    }
}
