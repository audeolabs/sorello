import DictationCore
import DictionaryKit
import FileTranscription
import Foundation
import MacPlatform
import Observation
import Persistence
import SorelloUI
import SpeechEngine
import Synchronization

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
    /// The speech model's download, as it last reported; nil in a copy that has no pin to download from.
    var modelDownload: ModelDownloadState?
}

/// What the windows ask the app shell to do: show a window or one of its sheets, or quit.
struct Navigation {
    var openMain: @MainActor (MainSection?) -> Void = { _ in }
    var openSetup: @MainActor () -> Void = {}
    var closeSetup: @MainActor () -> Void = {}
    /// Brings Transcribe File forward, opening it if it is closed.
    var showTranscribe: @MainActor () -> Void = {}
    /// Shows the file picker as a sheet on Transcribe File, and hands over the file chosen, if any.
    var chooseAudioFile: @MainActor (_ chosen: @escaping @MainActor (URL) -> Void) -> Void = { _ in }
    /// Shows the save panel as a sheet on Transcribe File, offering `name`, and writes `text` where the user chooses.
    var saveText: @MainActor (_ text: String, _ name: String) -> Void = { _, _ in }
    /// Brings a window that is open in front again, as after the system's microphone prompt; a closed one stays shut.
    var bringBack: @MainActor (AppWindow) -> Void = { _ in }
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
    /// Transcribes Transcribe File's files with `speech`.
    let files: any FileTranscribing
    /// The model's download, made beside the engine; nil in a copy that has no pin to download from.
    let download: (any ModelDownloading)?
    /// The app's updater; nil in a build with no update feed, and in the self-tests and the snapshots.
    let updater: (any Updating)?
    private let defaults: UserDefaults
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
    /// - `download`: the model's download, which nothing starts but the user.
    /// - `updater`: checks for, downloads and installs a newer version, in a build that has an update feed.
    /// - `modelFitsThisMac`: whether the app's pin has a build for this Mac, so a file's transcription can tell a model
    ///   not yet downloaded from none at all. A copy without a pin, given its model directly, has one.
    /// - `pill`: where the pill is drawn; `levels` is the feed it draws the voice from.
    init(info: AppInfo, storage: AppStorage, platform: AppPlatform,
         speech makeSpeech: (DictionaryStore) -> any AppSpeech, download: (any ModelDownloading)? = nil,
         updater: (any Updating)? = nil, modelFitsThisMac: Bool = true, pill: any PillPresenting,
         levels: LevelFeed) {
        self.info = info
        self.updater = updater
        defaults = storage.defaults
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
        // The vocabulary comes with the model: from the store or the app's own copy when the app has a pin, and only
        // once its manifest is the pinned one; otherwise from a model given on the command line.
        self.download = download
        let encoder = download.map { $0.vocabulary() }
            ?? info.modelDirectory.flatMap { try? BPEEncoder(vocabularyFile: $0.appendingPathComponent("vocabulary.json")) }
        let store = DictionaryStore(fileURL: paths.dictionaryFile, encoder: encoder)
        let dictionary = DictionaryLibrary(store: store, encoder: encoder)
        self.dictionary = dictionary
        let speech = makeSpeech(store)
        self.speech = speech
        files = speech.fileTranscriber(modelFitsThisMac: modelFitsThisMac)
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
        platform.shortcuts.setBindings(settings.shortcutBindings)
        platform.shortcuts.start()
        follow()
        watchSystem()
        watchDownload()
        // The app follows only the feed in its Info.plist: one left in the preferences is removed before the updater
        // could read it.
        defaults.removeObject(forKey: Updates.storedFeedKey)
        updater?.start()
    }

    /// Starts the model's download. Only the user's Download, in setup or on the General screen, calls this.
    func startDownload() {
        download?.start()
    }

    /// Stops the model's download; what arrived is kept.
    func cancelDownload() {
        download?.cancel()
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
        // Whichever comes first: the inserter idle, or the limit. The inserter's wait cannot be cancelled, so it is
        // left behind rather than waited for.
        let inserter = platform.inserter
        let clock = platform.clock
        let first = FirstOnly()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finish: @Sendable () -> Void = {
                if first.claim() { continuation.resume() }
            }
            Task {
                await inserter.waitUntilIdle()
                finish()
            }
            Task {
                try? await clock.sleep(for: limit)
                finish()
            }
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

    /// Follows the download: once it has put the model in the store, the engine is asked to prepare and the
    /// dictionary takes the vocabulary, without a relaunch. When the engine finds the model missing although the
    /// download said it was here, the download looks again, so it offers itself once more.
    private func watchDownload() {
        guard let download else { return }
        let live = self.live, runtime = self.runtime, dictionary = self.dictionary, speech = self.speech
        live.modelDownload = download.current
        let states = download.states()
        watching.append(Task { @MainActor in
            for await state in states {
                let arrived = state == .installed && live.modelDownload != .installed
                live.modelDownload = state
                guard arrived else { continue }
                if let encoder = download.vocabulary() { dictionary.adoptVocabulary(encoder) }
                Task { await Self.prepareAfterArrival(speech) }
            }
        })
        following.append(Following {
            if runtime.state.engine == .failed(.modelMissing) && live.modelDownload == .installed { download.refresh() }
        })
    }

    /// Asks the engine to prepare now that the model is in the store. A preparation already under way may have
    /// looked before the model arrived; asking joins it, and if it ends without the model, asking once more starts an
    /// attempt that looks again. Any other ending is left as it is, so a model that failed to load is not loaded twice.
    nonisolated private static func prepareAfterArrival(_ speech: any AppSpeech) async {
        await speech.prepare()
        var now: EngineReadiness?
        for await readiness in speech.readiness() {
            now = readiness
            break
        }
        if now == .failed(.modelMissing) { await speech.prepare() }
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

/// True for the first caller only, from any thread.
nonisolated private final class FirstOnly: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}
