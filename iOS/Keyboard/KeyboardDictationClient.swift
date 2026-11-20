import UIKit
#if SORELLO_KEYBOARD_DICTATION
import AVFAudio
import TextRules
#endif

/// What the dictation client needs from the input view controller. Document identifiers and text
/// context pass through and live no longer than this keyboard instance's memory.
@MainActor
protocol KeyboardTextTarget: AnyObject {
    var hasFullAccess: Bool { get }
    var documentID: UUID? { get }
    var contextBeforeInput: String? { get }
    var contextAfterInput: String? { get }
    /// The view haptics attach to; nil before it loads.
    var feedbackView: UIView? { get }
    /// Inserts a dictation's text; with `watching`, its request, the editing side watches it for a correction
    /// (ARCHITECTURE.md, "Dictation corrections").
    func insert(_ text: String, watching requestID: UUID?)
    /// A dictation is starting: the watch of the last one ends.
    func dictationStarting()
    /// The editing side is busy (a trackpad gesture is running or settling): results stay in the
    /// shared files until it is done, rather than waiting in memory.
    var isEditingBusy: Bool { get }
    /// "Undo last dictation" is owned by the editing side (`KeyboardInput`), which sees every edit.
    var canUndoLastDictation: Bool { get }
    func undoLastDictation()
    /// Tries to open the containing app (see `HostAppLauncher`); false if no attempt was made.
    func openContainingApp(_ url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) -> Bool
}

/// What the pad renders. It never holds transcript text.
struct KeyboardViewState: Equatable {
    var mode: KeyboardMode = .hostUnavailable
    var title = ""
    var hint: String?
    /// A short-lived notice (a failed write, no speech, open Sorello). Shown before any idle hint.
    var notice: String?
    var canInsertLast = false
    /// The last inserted dictation can still be removed (see `UndoTracker`).
    var canUndo = false
    /// For the menu panel: whether a session runs and how long it stays idle.
    var sessionSummary = ""
    /// A live session can take a dictation now (`KeyboardMessages.isSessionReady`): Start's dot is aurora.
    var sessionReady = false
    /// The status the bar shows as a mark rather than words, for VoiceOver (`KeyboardMessages.spokenStatus`).
    var spokenStatus: String?
    /// Recent input levels while recording, oldest first.
    var levels: [Float] = []
    /// How many levels this recording has heard, the newest's number (the wave keeps each level on its side by it).
    var levelSerial = 0
    /// The dictation shown (the intent's request), and the last one this keyboard put into a field: Cancel's bud
    /// becomes Undo only when they are the same (`IslandBud.target`). Random identifiers, in memory only.
    var dictationRequestID: UUID?
    var lastInsertedRequestID: UUID?
    /// The host is alive (`KeyboardPresenter.isHostAlive`): the "Add to dictionary" offer may show.
    var hostAlive = false
    /// Start would dictate in the keyboard (ARCHITECTURE.md, "In-keyboard dictation (experiment)"): nothing is said
    /// about opening Sorello.
    var startDictatesInKeyboard = false
    /// The in-keyboard attempt the bar shows running: Stop and Cancel act on it alone.
    var localAttemptID: UUID?
    /// The result "Insert last dictation" offers, by id: a host result's request, or an in-keyboard attempt's.
    var chipResultID: UUID?
}

/// The keyboard side of the protocol in ARCHITECTURE.md. While visible it polls and observes the
/// shared files, writes presence and intents, and claims and inserts results. The decisions come
/// from `KeyboardPresenter` and `KeyboardResultLedger`; this class only sequences them.
@MainActor
final class KeyboardDictationClient: ObservableObject {
    static let pollInterval: TimeInterval = 0.2
    /// Enough for the recording wave to span a landscape bar.
    static let levelHistoryCount = 72
    private static let noticeDuration: TimeInterval = 4

    @Published private(set) var state = KeyboardViewState()

    /// Names this `UIInputViewController` instance in the intents and presence it writes.
    let instanceID = UUID()
    weak var target: KeyboardTextTarget?

    private let configuration = SorelloConfiguration.main
    private var store: SharedDictationStore?
    private var ledger = KeyboardResultLedger()
    /// The result files as last read; most passes decide from it without touching the files.
    private var resultInbox = KeyboardResultInbox()
    private var isVisible = false
    private var hapticsEnabled = false
    private var keyHapticsEnabled = false
    private var generators: (impact: UIImpactFeedbackGenerator, notification: UINotificationFeedbackGenerator)?
    private var timers: [Timer] = []
    private var observations: [DarwinNotifier.Observation] = []
    /// The records behind `state`, so a tap acts on the request the user saw.
    private var shownIntent = StoreRead<KeyboardIntent>.absent
    private var shownStatus = StoreRead<HostStatus>.absent
    private var manualInsertID: UUID?
    private var launcherFailed = false
    /// The record request this instance last bounced to Sorello: until the host picks it up, Start stays Start
    /// (`KeyboardPresenter.shownMode`).
    private var bouncedRequestID: UUID?
    private var notice: (text: String, until: Date)?
    /// The notice up names a word sent to the dictionary: hiding forgets it with the word.
    private var noticeNamesWord = false
    private var levels: [Float] = []
    private var levelSerial = 0
    private var lastInsertedRequestID: UUID?
    private var levelSampledAt: Date?
    /// The word handed to the app and the record's id, until its outcome arrives or the keyboard hides
    /// (ARCHITECTURE.md, "Dictation corrections", Accepting). In memory only.
    private var pendingWord: (id: UUID, word: String)?
    /// When the keyboard next judges `added-word.json` while visible ("Files", One added word).
    private var addedWordPurge: Timer?
    /// How long "Adding “word”…" may show while the app decides; its outcome replaces it sooner.
    private static let addingNoticeDuration: TimeInterval = 10
    #if SORELLO_KEYBOARD_DICTATION
    /// In-keyboard dictation (ARCHITECTURE.md, "In-keyboard dictation (experiment)"), made when first needed.
    private var local: KeyboardLocalDictation?
    /// `keyboardDictationEnabled` and the app's microphone permission, read when the keyboard appears and at a tap.
    private var keyboardDictationEnabled = false
    private var microphoneGranted = false
    /// The shared `useBuiltInMicrophone`, read when the keyboard appears, for the held microphone; a tap reads it afresh.
    private var useBuiltInMicrophone = true
    /// Bluetooth headphones as the held microphone sees them, through the receiver's blips at each switch.
    private var headphones = KeyboardMicrophoneHold.HeadphonesWatch()
    /// The app's `Model/bundle.json` is readable from the keyboard, as of when the keyboard appeared.
    private var modelCarried = false
    /// Set from `viewWillDisappear` until the keyboard appears again: no in-keyboard dictation starts meanwhile.
    private var hiding = false
    /// The dictation the chip showed, by id: a host result's request, or an in-keyboard attempt.
    private var chipLocalAttempt: UUID?
    /// The last in-keyboard attempt, and when it began, for Cancel's bud and Undo (`dictationRequestID`).
    private var lastLocalAttempt: (id: UUID, at: Date)?
    /// Unfinished records of another keyboard process this process has handled, by attempt id: each sends one tap to
    /// the host, even if its rewrite as abandoned failed.
    private static var handledAbandonedAttempts: Set<UUID> = []
    private var refreshQueued = false
    #endif

    private var notifier: DarwinNotifier? { configuration.map(DarwinNotifier.init(configuration:)) }

    /// Haptics need Full Access and the user's setting; the keys use the same rule with their own setting.
    var hapticsAllowed: Bool { hapticsEnabled }
    var keyHapticsAllowed: Bool { keyHapticsEnabled }

    private var access: KeyboardAccess {
        guard target?.hasFullAccess == true else { return .noFullAccess }
        return store == nil ? .containerUnavailable : .fullAccess
    }

    // MARK: Lifecycle

    /// Call from `viewWillAppear`. Polling, presence and observations run only while visible.
    func start() {
        guard !isVisible else { return }
        isVisible = true
        if store == nil, let configuration { store = SharedDictationStore(configuration: configuration) }
        hapticsEnabled = false
        keyHapticsEnabled = false
        // Without Full Access the mode cannot change while visible, so nothing needs polling.
        if access == .fullAccess, let configuration, let notifier {
            let settings = SorelloSettings(configuration: configuration)
            hapticsEnabled = settings?.hapticsEnabled ?? false
            keyHapticsEnabled = settings?.keyHapticsEnabled ?? false
            #if SORELLO_KEYBOARD_DICTATION
            keyboardDictationEnabled = settings?.keyboardDictationEnabled ?? false
            microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
            useBuiltInMicrophone = settings?.useBuiltInMicrophone ?? true
            modelCarried = KeyboardSpeech.carriedModel() != nil
            hiding = false
            #endif
            observations = [notifier.observe(.status) { [weak self] in self?.refresh() },
                            notifier.observe(.result) { [weak self] in self?.resultPosted() }]
            let poll = Timer.mainLoop(after: Self.pollInterval, repeats: true, tolerance: 0.05) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                self.refresh()
            }
            let presence = Timer.mainLoop(after: DictationProtocol.keyboardPresenceInterval, repeats: true,
                                          tolerance: 0.05) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                self.writePresence()
            }
            timers = [poll, presence]
            writePresence()
            // The keyboard deletes an expired added word when it appears ("Files", One added word).
            purgeAddedWord()
        }
        refresh()
    }

    #if SORELLO_KEYBOARD_DICTATION
    /// Call from `viewWillDisappear`: hiding ends an in-keyboard dictation at once, and its waiting text goes.
    func willHide() {
        hiding = true
        headphones.reset()
        local?.hide()
        chipLocalAttempt = nil
    }

    /// A memory warning: counted while an in-keyboard dictation runs, else the engine is released.
    func memoryWarning() {
        local?.memoryWarning()
    }
    #endif

    /// Call from `viewDidDisappear`.
    func stop() {
        #if SORELLO_KEYBOARD_DICTATION
        willHide()
        #endif
        isVisible = false
        timers.forEach { $0.invalidate() }
        timers = []
        observations.forEach { $0.cancel() }
        observations = []
        levels = []
        levelSerial = 0
        levelSampledAt = nil
        // Hiding forgets the word on its way, and every notice that names it; an outcome that arrives later shows
        // nothing.
        pendingWord = nil
        if noticeNamesWord {
            notice = nil
            noticeNamesWord = false
            state.notice = nil
        }
        addedWordPurge?.invalidate()
        addedWordPurge = nil
        // No field identity outlives the keyboard being visible: a request bound to a field is never
        // auto-inserted after hiding (it stays available as "Insert last dictation").
        ledger.forgetFieldBindings()
        manualInsertID = nil
        // No transcript stays in memory while hidden; the next appearance reads the files again.
        resultInbox.reset()
    }

    /// Call from `viewWillAppear` and `textDidChange`: a new field invalidates bindings to others.
    func documentChanged(to documentID: UUID?) {
        ledger.documentChanged(to: documentID)
        #if SORELLO_KEYBOARD_DICTATION
        local?.focus(documentID)
        #endif
    }

    // MARK: Actions

    /// `shown`: the state the bar drew the tapped control from. Returns whether an in-keyboard dictation the bar showed
    /// was stopped (false for every other tap).
    @discardableResult
    func micTapped(shown: KeyboardViewState? = nil) -> Bool {
        notice = nil
        #if SORELLO_KEYBOARD_DICTATION
        // The in-keyboard dictation the bar showed takes the tap, whatever the host publishes; once it has ended, the
        // tap does nothing. A Start drawn before one began does nothing either.
        if let attempt = (shown ?? state).localAttemptID {
            let stopped = local?.stop(attempt) ?? false
            refresh()
            return stopped
        }
        if local?.isRunning == true || hiding {
            refresh()
            return false
        }
        switch state.mode {
        case .ready, .preparingModel, .hostUnavailable, .error:
            switch routeTap() {
            case .keyboard:
                refresh()
                return false
            case .host(let status, let intent):
                // As a host tap, from the same fresh status and intent the route read.
                let now = Date()
                actAsHostTap(in: KeyboardPresenter.shownMode(
                    KeyboardPresenter.mode(access: access, status: status, intent: intent, now: now),
                    bouncedRequestID: bouncedRequestID, intent: intent, status: status), status: status, intent: intent)
                refresh()
                return false
            case .notConsidered: break
            }
        default:
            break
        }
        #endif
        actAsHostTap(in: state.mode)
        refresh()
        return false
    }

    /// The mic tap's host path ("Mic tap"), for the mode `mode`; an error starts from `status`, and a finish names
    /// `intent`'s request (the shown ones if nil).
    private func actAsHostTap(in mode: KeyboardMode, status: StoreRead<HostStatus>? = nil,
                              intent: StoreRead<KeyboardIntent>? = nil) {
        switch mode {
        case .ready, .preparingModel: startDictation(openingHost: false)
        case .hostUnavailable: startDictation(openingHost: true)
        case .error:
            // The error is informational; start the way the host's current state allows.
            startAsHostTap(status: status)
        case .starting, .recording: send(.finish, requestID: intent?.value?.requestID)
        case .voiceNote: stopNote()
        case .transcribing, .waitingForModel, .needsFullAccess, .configurationError, .incompatible: break
        }
    }

    /// Stop note: a request of its own, which needs no authentication and binds nothing (ARCHITECTURE.md, "Keyboard
    /// extension", Stop note).
    private func stopNote() {
        guard let store, write(KeyboardIntent(requestID: UUID(), action: .stopNote, keyboardInstanceID: instanceID,
                                              issuedAt: Date()), to: store) else { return }
        notifier?.post(.intent)
        playHaptic(.press)
    }

    func cancelTapped(shown: KeyboardViewState? = nil) {
        notice = nil
        #if SORELLO_KEYBOARD_DICTATION
        if let attempt = (shown ?? state).localAttemptID {
            local?.cancel(attempt)
            return refresh()
        }
        if local?.isRunning == true { return refresh() }
        #endif
        switch state.mode {
        case .starting, .recording, .transcribing, .waitingForModel: send(.cancel)
        default: break
        }
        refresh()
    }

    /// The "Insert last dictation" chip: claims the offered result and inserts it into this field.
    func insertLastDictation(shown: KeyboardViewState? = nil) {
        notice = nil
        #if SORELLO_KEYBOARD_DICTATION
        // The chip acts on the result it showed, by id, and does nothing if that one has expired or been taken.
        let shownChip = (shown ?? state).chipResultID
        guard local?.isRunning != true, let shownChip else { return refresh() }
        if shownChip != manualInsertID {
            if let local, let store, let target, !target.isEditingBusy {
                // Checked again right before the text is delivered: the host owning the microphone drops it.
                if KeyboardDictationRoute.hostOwnsMicrophone(access: access, status: store.readStatus(),
                                                             intent: store.readIntent(), instanceID: instanceID, now: Date()) {
                    local.dropText(shownChip)
                } else if let result = local.takeOfferedText(shownChip) {
                    var context = target.contextBeforeInput
                    insertLocal(result, context: &context)
                }
            }
            return refresh()
        }
        #endif
        if let store, let target, !target.isEditingBusy, let requestID = manualInsertID {
            let read = store.readResult(requestID: requestID)
            if let result = read.value,
               ledger.disposition(of: result, documentID: target.documentID, now: Date()) != .ignore {
                var context = target.contextBeforeInput
                insert(result, context: &context)
            } else if read == .absent {
                // Removed elsewhere: stop offering it, so the pass below offers the next result.
                resultInbox.discard([requestID])
            }
        }
        refresh()
    }

    /// "Undo": removes the last inserted dictation, progressively, while it is still owned.
    func undoLastDictation() {
        notice = nil
        guard target?.canUndoLastDictation == true else { return publishUndoState() }
        target?.undoLastDictation()
        playHaptic(.press)
        publishUndoState()
    }

    /// Whether Undo can be offered changed. Updates only that, without reading the shared files or
    /// delivering a result, so an invalidation inside an edit can never insert text before the edit
    /// runs.
    func publishUndoState() {
        let canUndo = target?.canUndoLastDictation == true
        guard canUndo != state.canUndo else { return }
        state.canUndo = canUndo
    }

    /// The user tapped "Add “word” to dictionary" (ARCHITECTURE.md, "Dictation corrections", Accepting): the word, its
    /// dictation and range go to the app in `added-word.json`, `.addedWord` wakes it, and the word waits in memory
    /// for the app's outcome. A failed write says so.
    func addToDictionary(_ offer: DictationCorrectionOffer) {
        guard access == .fullAccess, let store else { return }
        let word = AddedWord(id: UUID(), requestID: offer.requestID, word: offer.word,
                             replacedStart: offer.replacedWords.lowerBound, replacedEnd: offer.replacedWords.upperBound,
                             issuedAt: Date())
        do {
            try store.writeAddedWord(word)
        } catch {
            pendingWord = nil
            show(KeyboardMessages.couldNotAdd(offer.word), namesWord: true)
            playHaptic(.failure)
            refresh()
            return
        }
        notifier?.post(.addedWord)
        pendingWord = (word.id, offer.word)
        show(KeyboardMessages.addingWord(offer.word), for: Self.addingNoticeDuration, namesWord: true)
        playHaptic(.press)
        scheduleAddedWordPurge(at: word.issuedAt + DictationProtocol.addedWordTTL)
        refresh()
    }

    /// Judges `added-word.json` where it lies and removes it only once it has expired; while visible, again at its
    /// deadline, or `cleanupRetryInterval` after a failed removal, until it is gone.
    private func purgeAddedWord() {
        addedWordPurge?.invalidate()
        addedWordPurge = nil
        guard isVisible, access == .fullAccess, let store else { return }
        switch store.purgeExpiredAddedWord(now: Date()) {
        case .absent, .removed: break
        case .kept(let deadline): scheduleAddedWordPurge(at: deadline)
        case .failed: scheduleAddedWordPurge(at: Date() + KeyboardResultInbox.cleanupRetryInterval)
        }
    }

    private func scheduleAddedWordPurge(at date: Date) {
        addedWordPurge?.invalidate()
        // Just past the deadline, so the file is no longer fresh when it is judged.
        addedWordPurge = Timer.mainLoop(after: max(date.timeIntervalSinceNow, 0) + 0.05) { [weak self] _ in
            self?.purgeAddedWord()
        }
    }

    /// The app's outcome for the word on its way, once the status names it.
    private func showAddedWordOutcome(_ status: StoreRead<HostStatus>) {
        guard let pending = pendingWord, let outcome = status.value?.addedWord, outcome.id == pending.id else { return }
        pendingWord = nil
        show(KeyboardMessages.addedWord(pending.word, outcome: outcome.outcome, strength: outcome.strength), namesWord: true)
        playHaptic(outcome.outcome == .added ? .success : .failure)
    }

    /// "Open Sorello" in the menu: the same launcher as the bounce, without a dictation request.
    func openSorello() {
        notice = nil
        var attempted = false
        if let url = configuration?.dictateURL, let target {
            attempted = target.openContainingApp(url) { [weak self] opened in
                guard let self, !opened else { return }
                self.launcherFailed = true
                self.show(KeyboardMessages.openSorello)
                self.refresh()
            }
        }
        if !attempted {
            launcherFailed = true
            show(KeyboardMessages.openSorello)
        }
        refresh()
    }

    /// Starts the way the host's state allows ("Mic tap"), as a tap on Start would.
    private func startAsHostTap(status: StoreRead<HostStatus>? = nil) {
        switch KeyboardPresenter.mode(access: access, status: status ?? shownStatus, intent: .absent, now: Date()) {
        case .ready, .preparingModel: startDictation(openingHost: false)
        case .hostUnavailable: startDictation(openingHost: true)
        default: break
        }
    }

    #if SORELLO_KEYBOARD_DICTATION
    private enum TapRoute {
        /// An in-keyboard dictation started.
        case keyboard
        /// The host's path, from this freshly read status and intent.
        case host(StoreRead<HostStatus>, StoreRead<KeyboardIntent>)
        /// The experiment is off here: the tap goes on as it always has.
        case notConsidered
    }

    /// The route at a tap that would start (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Route), from the
    /// freshly read status and intent. A record another keyboard process left unfinished is first rewritten as
    /// abandoned, and that one tap goes to the host.
    private func routeTap() -> TapRoute {
        guard keyboardDictationEnabled, access == .fullAccess, let store, let target else { return .notConsidered }
        microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
        var unfinished = false
        if let attempt = unhandledUnfinishedRecord(in: store) {
            // Handled once per process, even if the rewrite fails.
            Self.handledAbandonedAttempts.insert(attempt)
            _ = store.abandonUnfinishedKeyboardDictation(notWrittenBy: KeyboardLocalDictation.processID)
            unfinished = true
        }
        let status = store.readStatus()
        let intent = store.readIntent()
        let decision = KeyboardDictationRoute.decide(
            access: access, status: status, intent: intent, instanceID: instanceID, now: Date(),
            conditions: routeConditions(unfinishedRecord: unfinished))
        guard decision == .keyboard, let local = localDictation() else { return .host(status, intent) }
        // Another dictation's start ends the watch of the last one.
        target.dictationStarting()
        let settings = configuration.flatMap(SorelloSettings.init(configuration:))
        local.start(documentID: target.documentID, useBuiltInMicrophone: settings?.useBuiltInMicrophone ?? true)
        playHaptic(.press)
        return .keyboard
    }

    /// The attempt id of a record another keyboard process left unfinished that this process has not handled yet.
    private func unhandledUnfinishedRecord(in store: SharedDictationStore) -> UUID? {
        guard let record = store.readKeyboardDictation().value, let attempt = record.attemptID,
              record.isUnfinished(byAnotherProcessThan: KeyboardLocalDictation.processID),
              !Self.handledAbandonedAttempts.contains(attempt) else { return nil }
        return attempt
    }

    private func routeConditions(unfinishedRecord: Bool) -> KeyboardDictationRoute.Conditions {
        KeyboardDictationRoute.Conditions(
            hasFullAccess: target?.hasFullAccess == true, enabled: keyboardDictationEnabled,
            microphoneGranted: microphoneGranted, modelCarried: modelCarried,
            lastEndedCaptureUnavailable: local?.lastEndedCaptureUnavailable ?? false,
            unfinishedRecordOfAnotherProcess: unfinishedRecord)
    }

    /// The in-keyboard dictation, made the first time it is needed.
    private func localDictation() -> KeyboardLocalDictation? {
        if let local { return local }
        guard let store, let model = KeyboardSpeech.carriedModel() else { return nil }
        let instanceID = self.instanceID
        let made = KeyboardLocalDictation(store: store, modelDirectory: model, hooks: .init(
            container: { [weak self] in self?.target?.feedbackView },
            hostOwnsMicrophone: { [weak self] in
                guard let self, let store = self.store else { return false }
                return KeyboardDictationRoute.hostOwnsMicrophone(access: self.access, status: store.readStatus(),
                                                                 intent: store.readIntent(), instanceID: instanceID,
                                                                 now: Date())
            },
            ruleOptions: { [weak self] in
                let settings = self?.configuration.flatMap(SorelloSettings.init(configuration:))
                return TextRuleOptions(pressEnterCommand: settings?.pressEnterEnabled ?? true,
                                       spokenNumbers: settings?.spokenNumbersEnabled ?? true,
                                       spokenDelimiters: settings?.spokenDelimitersEnabled ?? true, promptTag: "")
            },
            handToHost: { [weak self] field in
                // Nothing was heard: on as a host tap, if the keyboard still shows the tap's field.
                guard let self, self.isVisible, !self.hiding, self.target?.documentID == field, let store = self.store
                else { return }
                self.startAsHostTap(status: store.readStatus())
            },
            noSpeech: { [weak self] in self?.show(KeyboardMessages.noSpeech) },
            level: { [weak self] level in self?.heardLocally(level) },
            changed: { [weak self] in self?.refreshSoon() }))
        local = made
        return made
    }

    /// The held microphone (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Capture, Held microphone), judged at
    /// every pass. The route is read only when everything else holds.
    private func updateHeldMicrophone(tapDictatesInKeyboard: Bool) {
        var conditions = KeyboardMicrophoneHold.Conditions(
            visible: isVisible && !hiding, tapDictatesInKeyboard: tapDictatesInKeyboard,
            useBuiltInMicrophone: useBuiltInMicrophone, bluetoothHeadphones: false,
            dictationCapturing: local?.isCapturing == true, heldCaptureReported: local?.heldCaptureReported == true)
        if conditions.visible, tapDictatesInKeyboard, useBuiltInMicrophone, !conditions.dictationCapturing,
           !conditions.heldCaptureReported {
            conditions.bluetoothHeadphones = headphones.observe(
                KeyboardMicrophoneHold.bluetoothHeadphones(in: Self.routeOutputs()), at: ProcessInfo.processInfo.systemUptime)
        }
        if KeyboardMicrophoneHold.shouldHold(conditions) {
            localDictation()?.hold(true)
        } else {
            local?.hold(false)
        }
    }

    /// The audio session's current route's outputs: read only, never configured.
    private static func routeOutputs() -> [KeyboardMicrophoneHold.Output] {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { port in
            switch port.portType {
            case .bluetoothA2DP: return .bluetoothA2DP
            case .bluetoothLE: return .bluetoothLE
            case .bluetoothHFP: return .bluetoothHFP
            default: return .other
            }
        }
    }

    /// A chunk of the in-keyboard recording: one bar of the wave.
    private func heardLocally(_ level: Float) {
        levels.append(level)
        levelSerial += 1
        levels.removeFirst(max(0, levels.count - Self.levelHistoryCount))
        refreshSoon()
    }

    /// A pass after the current one: in-keyboard dictation's changes never run a pass inside another.
    private func refreshSoon() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.refresh()
        }
    }

    /// An in-keyboard text, inserted as a host result is, without a correction watch.
    private func insertLocal(_ result: DictationResult, context: inout String?) {
        guard let target else { return }
        let text = TextInsertionFormatter.text(for: result, contextBefore: context, contextAfter: target.contextAfterInput)
        guard !text.isEmpty else { return show(KeyboardMessages.noSpeech) }
        target.insert(text, watching: nil)
        lastInsertedRequestID = result.requestID
        context = (context ?? "") + text
        local?.inserted(result.requestID)
        playHaptic(.success)
    }
    #endif

    private func startDictation(openingHost: Bool) {
        guard let store else { return }
        // Another dictation's start ends the watch of the last one.
        target?.dictationStarting()
        let requestID = UUID()
        guard write(KeyboardIntent(requestID: requestID, action: .record, keyboardInstanceID: instanceID,
                                   issuedAt: Date()), to: store) else { return }
        // Started in this field, so bound to it: a host auto-finish lands here if the keyboard stays
        // visible in this field.
        ledger.bindRecord(requestID: requestID, documentID: target?.documentID)
        bouncedRequestID = openingHost ? requestID : nil
        playHaptic(.press)
        guard openingHost else {
            // After the frame that starts the island's grow: the host's start (capture, the Live Activity) then runs
            // beside the spring rather than ahead of its first frames.
            DispatchQueue.main.async { [notifier] in notifier?.post(.intent) }
            return
        }
        // No `.intent` post: a background host without a session would reject the request before
        // the app reaches the foreground and admits it.
        var attempted = false
        if let url = configuration?.dictateURL, let target {
            attempted = target.openContainingApp(url) { [weak self] opened in
                if !opened { self?.launchFailed() }
            }
        }
        if !attempted { launchFailed() }
    }

    private func launchFailed() {
        launcherFailed = true
        playHaptic(.failure)
        refresh()
    }

    /// `finish` or `cancel` for the request on screen, under the stale-writer guard.
    /// `requestID`: the request a fresh read showed; the one on screen if nil.
    private func send(_ action: KeyboardIntent.Action, requestID: UUID? = nil) {
        guard let store, let requestID = requestID ?? shownIntent.value?.requestID,
              KeyboardPresenter.mayWrite(action, requestID: requestID, currentIntent: store.readIntent()),
              write(KeyboardIntent(requestID: requestID, action: action, keyboardInstanceID: instanceID,
                                   issuedAt: Date()), to: store)
        else { return }
        if action == .finish { ledger.bindFinish(requestID: requestID, documentID: target?.documentID) }
        notifier?.post(.intent)
        playHaptic(.press)
    }

    private func write(_ intent: KeyboardIntent, to store: SharedDictationStore) -> Bool {
        do {
            try store.writeIntent(intent)
            return true
        } catch {
            show(KeyboardMessages.storeWriteFailed)
            playHaptic(.failure)
            return false
        }
    }

    private func writePresence() {
        guard isVisible, access == .fullAccess, let store else { return }
        try? store.writePresence(KeyboardPresence(keyboardInstanceID: instanceID, seenAt: Date()))
    }

    // MARK: Passes

    /// `.result` arrived: the next pass reads the result files.
    private func resultPosted() {
        resultInbox.resultPosted()
        refresh()
    }

    /// One pass: read the status and intent, compute the mode, deliver results and publish. The
    /// result files are read only when `KeyboardResultInbox` says one may have arrived or expired.
    func refresh() {
        guard isVisible, let target else { return }
        let now = Date()
        let access = self.access
        let documentID = target.documentID
        // Also catches a focus change whose `textDidChange` has not arrived yet.
        ledger.documentChanged(to: documentID)
        var status = StoreRead<HostStatus>.absent
        var intent = StoreRead<KeyboardIntent>.absent
        if access == .fullAccess, let store {
            status = store.readStatus()
            intent = store.readIntent()
        }
        // Displaying a request never binds it, so a new instance in another app cannot auto-insert it.
        #if SORELLO_KEYBOARD_DICTATION
        var mode = KeyboardPresenter.shownMode(KeyboardPresenter.mode(access: access, status: status, intent: intent, now: now),
                                               bouncedRequestID: bouncedRequestID, intent: intent, status: status)
        var startDictatesInKeyboard = false
        if let local {
            local.focus(documentID)
            // Revoked on the first status read in which the host owns the microphone.
            if local.isRunning, KeyboardDictationRoute.hostOwnsMicrophone(access: access, status: status, intent: intent,
                                                                          instanceID: instanceID, now: now) {
                local.hostOwnsMicrophone()
            }
            // While one runs, or shows its failure, the host's status does not change the mode.
            if let localMode = local.mode { mode = localMode }
            if let attempt = local.runningAttemptID, lastLocalAttempt?.id != attempt { lastLocalAttempt = (attempt, now) }
        }
        if mode == .hostUnavailable, keyboardDictationEnabled, access == .fullAccess, let store {
            // Read only: the tap itself rewrites an unfinished record.
            startDictatesInKeyboard = KeyboardDictationRoute.decide(
                access: access, status: status, intent: intent, instanceID: instanceID, now: now,
                conditions: routeConditions(unfinishedRecord: unhandledUnfinishedRecord(in: store) != nil)) == .keyboard
        }
        // A dictation that transcribes does not keep the hold off: the route as the host's state decides it.
        var holdTapDictatesInKeyboard = startDictatesInKeyboard
        if local?.isRunning == true, local?.isCapturing == false, keyboardDictationEnabled, access == .fullAccess,
           let store {
            holdTapDictatesInKeyboard = KeyboardDictationRoute.decide(
                access: access, status: status, intent: intent, instanceID: instanceID, now: now,
                conditions: routeConditions(unfinishedRecord: unhandledUnfinishedRecord(in: store) != nil)) == .keyboard
        }
        updateHeldMicrophone(tapDictatesInKeyboard: holdTapDictatesInKeyboard)
        #else
        let mode = KeyboardPresenter.shownMode(KeyboardPresenter.mode(access: access, status: status, intent: intent, now: now),
                                               bouncedRequestID: bouncedRequestID, intent: intent, status: status)
        let startDictatesInKeyboard = false
        #endif
        ledger.prune(now: now, keeping: Set([intent.value?.requestID, shownIntent.value?.requestID].compactMap { $0 }))
        if access == .fullAccess { deliverResults(status: status, documentID: documentID, now: now) }
        shownIntent = intent
        shownStatus = status
        showAddedWordOutcome(status)
        #if SORELLO_KEYBOARD_DICTATION
        // The in-keyboard recording's wave comes from its own chunks (`heardLocally`).
        if local?.isRunning != true { sampleLevel(of: mode, status: status) }
        #else
        sampleLevel(of: mode, status: status)
        #endif
        publish(mode, intent: intent, status: status, now: now, startDictatesInKeyboard: startDictatesInKeyboard)
    }

    private func deliverResults(status: StoreRead<HostStatus>, documentID: UUID?, now: Date) {
        guard let store else { return }
        // Purges, lists and decodes the result files only when a read is due; otherwise the results
        // read earlier stand in for them, so a deferred one is still delivered on a later pass.
        resultInbox.update(from: store, status: status, now: now)
        let plan = ledger.plan(for: resultInbox.results, documentID: documentID, now: now)
        #if SORELLO_KEYBOARD_DICTATION
        if let local {
            // While one runs, host results are read but none is claimed or inserted, nor offered.
            guard !local.isRunning else {
                manualInsertID = nil
                chipLocalAttempt = nil
                return
            }
            // Then oldest first, one per pass, once the editing side is not busy: the local text chosen is the one taken.
            if let target, !target.isEditingBusy, let next = local.nextBoundText,
               plan.autoInsert.first.map({ next.createdAt <= $0.createdAt }) ?? true {
                manualInsertID = plan.manualInsert?.requestID
                // The host may own the microphone by now: checked again right before the text is delivered. Then it
                // is dropped, and nothing else is inserted on this pass.
                // Read afresh here, not at the pass's start: the host may have published since.
                if KeyboardDictationRoute.hostOwnsMicrophone(access: access, status: store.readStatus(),
                                                             intent: store.readIntent(), instanceID: instanceID,
                                                             now: Date()) {
                    local.dropText(next.requestID)
                } else if let result = local.takeBoundText(next.requestID) {
                    var context = target.contextBeforeInput
                    insertLocal(result, context: &context)
                }
                // Expired between the choice and the take: the next pass chooses again.
                return
            }
            // The chip offers the newest of either kind.
            if let offered = local.offeredText, plan.manualInsert.map({ offered.createdAt >= $0.createdAt }) ?? true {
                chipLocalAttempt = offered.requestID
            } else {
                chipLocalAttempt = nil
            }
        }
        #endif
        // At most one result per pass, oldest first: what it inserts (a Return) can move the host to
        // another field, so each one is bound again right before it is claimed, on a later pass. A result
        // is claimed only to be inserted at once: while a trackpad gesture runs, it stays in the shared
        // files.
        if let next = plan.autoInsert.first, let target, !target.isEditingBusy,
           ledger.disposition(of: next, documentID: target.documentID, now: Date()) == .autoInsert {
            var context = target.contextBeforeInput
            insert(next, context: &context)
        }
        // A consumed request's file is gone, whoever removed it.
        resultInbox.discard(ledger.consumed)
        // The ledger never offers a result that would insert nothing.
        manualInsertID = plan.manualInsert?.requestID
        #if SORELLO_KEYBOARD_DICTATION
        if chipLocalAttempt != nil { manualInsertID = nil }
        #endif
    }

    /// Claim before insert: the result is inserted only if this call deleted its file, so it lands
    /// at most once across keyboard instances and processes.
    private func insert(_ result: DictationResult, context: inout String?) {
        guard let store, let target, ledger.claim(requestID: result.requestID, in: store) else { return }
        // Already ends in "\n" when the result presses Enter, even for an empty transcript.
        let text = TextInsertionFormatter.text(for: result, contextBefore: context, contextAfter: target.contextAfterInput)
        guard !text.isEmpty else {
            show(KeyboardMessages.noSpeech)
            return
        }
        // A result that presses Return is not watched for a correction.
        target.insert(text, watching: result.pressEnter ? nil : result.requestID)
        lastInsertedRequestID = result.requestID
        // The proxy may not reflect the insertion yet, and a following result's spacing needs it.
        context = (context ?? "") + text
        playHaptic(.success)
    }

    private func sampleLevel(of mode: KeyboardMode, status: StoreRead<HostStatus>) {
        guard case .recording(let level, _) = mode else {
            levels = []
            levelSerial = 0
            levelSampledAt = nil
            return
        }
        // One bar per status the host publishes, not per read.
        let sampledAt = status.value?.heartbeatAt
        guard sampledAt != levelSampledAt else { return }
        levelSampledAt = sampledAt
        levels.append(level)
        levelSerial += 1
        levels.removeFirst(max(0, levels.count - Self.levelHistoryCount))
    }

    private func publish(_ mode: KeyboardMode, intent: StoreRead<KeyboardIntent>, status: StoreRead<HostStatus>,
                         now: Date, startDictatesInKeyboard: Bool) {
        var title = KeyboardMessages.title(for: mode, launcherFailed: launcherFailed, dictatesInKeyboard: startDictatesInKeyboard)
        #if SORELLO_KEYBOARD_DICTATION
        // The in-keyboard attempt is the dictation shown when it is newer than the host's request.
        let dictationRequestID = lastLocalAttempt.flatMap { last in
            intent.value.map { $0.issuedAt <= last.at } ?? true ? last.id : nil
        } ?? intent.value?.requestID
        let canInsertLast = manualInsertID != nil || chipLocalAttempt != nil
        let localAttemptID = local?.runningAttemptID
        let chipResultID = chipLocalAttempt ?? manualInsertID
        #else
        let dictationRequestID = intent.value?.requestID
        let canInsertLast = manualInsertID != nil
        let localAttemptID: UUID? = nil
        let chipResultID = manualInsertID
        #endif
        if case .recording = mode, KeyboardPresenter.isModelPreparing(status: status, now: now) {
            title = KeyboardMessages.listeningWhilePreparing
        }
        // A notice is rendered on its own, so no mode (ready included) can hide it.
        if let current = notice, current.until <= now { notice = nil }
        let next = KeyboardViewState(mode: mode, title: title, hint: KeyboardMessages.hint(for: status.value, now: now),
                                     notice: notice?.text,
                                     canInsertLast: canInsertLast,
                                     canUndo: target?.canUndoLastDictation == true,
                                     sessionSummary: KeyboardMessages.sessionSummary(for: status.value, now: now),
                                     sessionReady: KeyboardMessages.isSessionReady(status.value, now: now),
                                     spokenStatus: KeyboardMessages.spokenStatus(mode: mode, status: status.value,
                                                                                 launcherFailed: launcherFailed, now: now,
                                                                                 dictatesInKeyboard: startDictatesInKeyboard),
                                     levels: levels, levelSerial: levelSerial, dictationRequestID: dictationRequestID,
                                     lastInsertedRequestID: lastInsertedRequestID,
                                     hostAlive: KeyboardPresenter.isHostAlive(status: status, now: now),
                                     startDictatesInKeyboard: startDictatesInKeyboard, localAttemptID: localAttemptID,
                                     chipResultID: chipResultID)
        guard next != state else { return }
        if mode.phase != state.mode.phase {
            if case .recording = mode { playHaptic(.listening) }
            if case .error = mode { playHaptic(.failure) }
        }
        if UIAccessibility.isVoiceOverRunning {
            if let notice = next.notice, notice != state.notice {
                UIAccessibility.post(notification: .announcement, argument: notice)
            } else if title != state.title {
                UIAccessibility.post(notification: .announcement, argument: title)
            }
        }
        state = next
    }

    private func show(_ text: String, for duration: TimeInterval? = nil, namesWord: Bool = false) {
        notice = (text, Date().addingTimeInterval(duration ?? Self.noticeDuration))
        noticeNamesWord = namesWord
    }

    // MARK: Haptics

    private enum Haptic { case press, listening, success, failure }

    private func playHaptic(_ haptic: Haptic) {
        // iOS plays keyboard haptics only with Full Access, and the user can turn them off in Sorello.
        guard hapticsEnabled, let view = target?.feedbackView else { return }
        let generators = self.generators ?? (impact: UIImpactFeedbackGenerator(style: .medium, view: view),
                                             notification: UINotificationFeedbackGenerator(view: view))
        self.generators = generators
        switch haptic {
        case .press: generators.impact.impactOccurred(intensity: 0.6)
        case .listening: generators.impact.impactOccurred()
        case .success: generators.notification.notificationOccurred(.success)
        case .failure: generators.notification.notificationOccurred(.error)
        }
    }
}

private extension KeyboardMode {
    /// The mode with recording details dropped, to compare phases.
    var phase: KeyboardMode {
        if case .recording = self { return .recording(level: 0, startedAt: .distantPast) }
        return self
    }
}
