import DesignCore
import DictationCore
import DictionaryKit
import Foundation
import MacPlatform
import Observation
import Persistence
import SorelloUI
import SpeechEngine

/// Where the app keeps its data: the directory and the settings' defaults. The app's are under its bundle
/// identifier; tests and the self-test pass temporary ones.
struct AppStorage {
    let paths: AppPaths
    let defaults: UserDefaults
}

/// What the app knows that no store keeps: what the system says now, and what the windows are in the middle of.
@MainActor
@Observable
final class LiveState {
    /// Whether Sorello is trusted for Accessibility, as last read.
    var accessibilityTrusted = false
    /// The microphones connected now.
    var microphones: [AudioInputDevice] = []
    /// The shortcut being recorded, if any.
    var recording: ShortcutKind?
    /// The last refused recording for each action, until the next attempt.
    var refusals: [ShortcutKind: ShortcutRefusal] = [:]
    /// The Run Log entry whose audio is playing.
    var playingID: String?
    /// Run Log entries being transcribed again.
    var retryingIDs: Set<String> = []
}

/// What the windows ask the app shell to do: show a window, or quit.
struct Navigation {
    var openMain: @MainActor (MainSection?) -> Void = { _ in }
    var openSetup: @MainActor () -> Void = {}
    var closeSetup: @MainActor () -> Void = {}
    var showNotice: @MainActor (_ title: String, _ files: [URL]) -> Void = { _, _ in }
    var alert: @MainActor (_ title: String, _ message: String) -> Void = { _, _ in }
    var quit: @MainActor () -> Void = {}
}

/// The composition root (ARCHITECTURE.md, section 2): the only place that knows every module. It builds each object
/// once, from the stores to the session, and passes it where it is needed; there are no singletons. The app shell
/// owns one of these for the app's whole life, and with it the session runtime, which nothing else holds strongly.
@MainActor
final class AppComposition {
    let info: AppInfo
    let platform: AppPlatform
    let paths: AppPaths
    let settings: SettingsStore
    let macros: MacroStore
    let history: HistoryStore
    let dictionary: DictionaryLibrary
    let speech: any AppSpeech
    let runtime: SessionRuntime
    let corrections: CorrectionCoordinator
    let pill: any PillPresenting
    let live = LiveState()
    let relay: TriggerRelay
    /// What the windows ask of the shell; the shell fills it in.
    var navigation = Navigation()

    private var following: [Following] = []
    private var watching: [Task<Void, Never>] = []
    private var started = false

    /// Builds the whole graph. Nothing starts until `start()`: no tap, no model, no microphone.
    ///
    /// - `speech`: makes the engine over the dictionary store, whose snapshots it reads.
    /// - `pill`: where the pill is drawn; `levels` is the feed it draws the voice from.
    init(info: AppInfo, storage: AppStorage, platform: AppPlatform,
         speech makeSpeech: (DictionaryStore) -> any AppSpeech, pill: any PillPresenting, levels: LevelFeed) {
        self.info = info
        self.platform = platform
        paths = storage.paths
        do {
            try paths.prepare()
        } catch {
            // Each store creates the directory it writes into, so the app still works; it is only less private.
            Diagnostics.record("app.dataDirectoryNotPrepared")
        }
        let settings = SettingsStore(defaults: storage.defaults)
        self.settings = settings
        let macros = MacroStore(fileURL: paths.macrosFile)
        self.macros = macros
        history = HistoryStore(directory: paths.historyDirectory, isEnabled: { settings.keepRunLog })
        let encoder = info.modelDirectory.flatMap { try? BPEEncoder(vocabularyFile: $0.appendingPathComponent("vocabulary.json")) }
        let store = DictionaryStore(fileURL: paths.dictionaryFile, encoder: encoder)
        let dictionary = DictionaryLibrary(store: store, encoder: encoder)
        self.dictionary = dictionary
        let speech = makeSpeech(store)
        self.speech = speech
        self.pill = pill

        let live = self.live
        let frontmost = NotingFrontmostApp(platform.frontmostApp)
        let ports = SessionPorts(capture: platform.capture, speech: speech, inserter: platform.inserter,
                                 microphone: platform.microphone, frontmostApp: frontmost, history: history,
                                 levels: LevelFeedSink(feed: levels), clock: platform.clock)
        let runtime = SessionRuntime(
            ports: ports,
            settings: {
                SessionSettings(settings: settings, dictionaryEditable: dictionary.canEdit,
                                accessibilityTrusted: live.accessibilityTrusted)
            },
            textRules: { TextRulesSnapshot(settings: settings, macros: macros.macros) })
        self.runtime = runtime
        let relay = TriggerRelay(runtime: runtime)
        self.relay = relay
        let corrections = CorrectionCoordinator(
            settings: settings, dictionary: dictionary, engine: speech, clock: platform.clock,
            inputs: .init(session: { [weak runtime] in runtime?.state ?? SessionState() },
                          holdIsDown: { [weak relay] in relay?.holdIsDown ?? false },
                          accessibilityTrusted: { live.accessibilityTrusted }),
            makeWatcher: { onEdit, onAbandon in
                FieldCorrectionWatcher(watcher: CorrectionWatcher(reader: platform.fieldReader, onEdit: onEdit,
                                                                  onAbandon: onAbandon))
            })
        self.corrections = corrections
        relay.observer = { [weak corrections] in corrections?.triggerArrived($0) }

        frontmost.onRead = { [weak runtime, weak corrections] app in
            guard let id = runtime?.state.capture.live?.id else { return }
            corrections?.dictationStarted(id, app: app)
        }
        runtime.willInsert = { [weak corrections] id, _, destination in
            await corrections?.willInsert(id, destination: destination)
        }
        runtime.onCompletion = { [weak corrections] in corrections?.dictationCompleted($0) }
        dictionary.didChange = { [weak corrections] in corrections?.dictionaryChanged() }
        platform.shortcuts.handler = relay

        let clock = platform.clock
        pill.onStop = { [weak runtime] in runtime?.handle(.pillStopClicked, at: clock.now) }
        pill.onCancel = { [weak runtime] in runtime?.handle(.pillCancelClicked, at: clock.now) }
        pill.onNoticeAction = { [weak corrections] notice, action in
            guard AppNoticeID.isAppNotice(notice) else { return }
            corrections?.noticeAction(notice, action: action)
        }
    }

    /// Starts the app's work: reads the Run Log, starts the session (which prepares the model), the shortcuts and
    /// the loops that keep the pill and the monitor current. Later calls do nothing.
    func start() {
        guard !started else { return }
        started = true
        live.accessibilityTrusted = platform.accessibility.isTrusted
        live.microphones = platform.microphones.current()
        let history = self.history
        watching.append(Task { await history.load() })
        runtime.start()
        platform.shortcuts.start()
        follow()
        watchSystem()
    }

    /// The app came to the front: the user may have changed a permission or a login item in System Settings.
    func becameActive() {
        runtime.refreshMicrophoneAccess()
        live.accessibilityTrusted = platform.accessibility.isTrusted
        platform.shortcuts.start()
        platform.loginItem.refresh()
    }

    /// Lets go of everything before the app quits: no more shortcuts, any recording and any dictation not yet being
    /// pasted thrown away (which releases the microphone and the streams), the correction watch and its audio
    /// dropped, and a clipboard waiting to be put back put back. Returns within `limit` seconds whatever happens.
    func shutdown(limit: TimeInterval = 3) async {
        for loop in following { loop.stop() }
        following = []
        for task in watching { task.cancel() }
        watching = []
        corrections.quitting()
        platform.shortcuts.stop()
        // A recording is discarded by the first cancel, the pipeline by the second (rule 6). A paste already under
        // way is never retracted; it finishes, and its clipboard is restored, before the wait below returns.
        runtime.handle(.cancelPressed, at: platform.clock.now)
        runtime.handle(.cancelPressed, at: platform.clock.now)
        let inserter = platform.inserter
        let clock = platform.clock
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await inserter.waitUntilIdle() }
            group.addTask { try? await clock.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Keeping things current

    private func follow() {
        let runtime = self.runtime, corrections = self.corrections, pill = self.pill, settings = self.settings
        // The pill: the session's content first; the app's own notice only when the session shows nothing.
        following.append(Following {
            let session = runtime.pill
            if session != .hidden {
                corrections.preempt()
                pill.show(PillDisplay(session))
            } else if let notice = corrections.notice {
                pill.show(.notice(notice))
            } else {
                pill.show(.hidden)
            }
        })
        following.append(Following {
            pill.adjustments = PillAdjustments(islandHeight: settings.islandHeightNudge,
                                               islandOffset: settings.islandOffsetNudge)
        })
        // The shortcuts the monitor matches follow the settings.
        let shortcuts = platform.shortcuts
        var applied = settings.shortcutBindings
        following.append(Following {
            let bindings = settings.shortcutBindings
            guard bindings != applied else { return }
            applied = bindings
            shortcuts.setBindings(bindings)
        })
        // Turning suggestions off stops every part of them at once.
        var suggestionsOn = settings.correctionSuggestions
        following.append(Following {
            let on = settings.correctionSuggestions
            defer { suggestionsOn = on }
            if suggestionsOn && !on { corrections.suggestionsTurnedOff() }
        })
    }

    private func watchSystem() {
        let live = self.live, shortcuts = platform.shortcuts
        let trust = platform.accessibility.changes()
        watching.append(Task { @MainActor in
            for await trusted in trust {
                live.accessibilityTrusted = trusted
                // A grant in System Settings takes effect without a relaunch.
                if trusted { shortcuts.start() }
            }
        })
        let devices = platform.microphones.changes()
        watching.append(Task { @MainActor in
            for await list in devices { live.microphones = list }
        })
    }
}
