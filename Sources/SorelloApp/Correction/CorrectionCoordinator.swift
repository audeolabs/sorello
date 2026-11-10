import DictationCore
import DictionaryKit
import Foundation
import MacPlatform
import Observation
import Persistence
import SorelloUI

/// Correction suggestions from end to end (ARCHITECTURE.md, sections 4 and 5; docs/dictionary/DESIGN.md, sections
/// 3.4 to 3.6): when the user fixes a word right after dictating it, Sorello can offer to add the word.
///
/// - A dictation's start is noted with the watch generation, the dictionary revision and the app in front. Starting
///   a recording ends any watch and check before it.
/// - During the insertion (`willInsert`), the destination's token is opened into MacPlatform's prepared field and
///   bound to a watch. The coordinator never looks for the focused field itself; a clipboard-only destination has no
///   token and is never watched.
/// - When the dictation leaves the session, the watch starts only if the dictation was inserted, was not a macro,
///   pressed no Return, has a correction id and an anchor, and suggestions are on (`CorrectionEligibility`). Every
///   other ending releases the engine's audio.
/// - Each settled edit is checked by the engine. A suggestion is shown only if its watch can be claimed and no
///   dictation is under way; it is a pill notice with three or four actions that resolves as Not Now after 12 s.
/// - The user's choice is applied to the dictionary through `DictionaryLibrary`.
///
/// Cancelling (a new recording, suggestions turned off, a dictionary change, quitting) ends the watch, stops the check
/// and releases the audio; turning suggestions off or a dictionary change also withdraws a visible suggestion.
@MainActor
@Observable
final class CorrectionCoordinator {
    /// The notice the pill shows for the app, when the session has nothing to show: a suggestion, or a word that
    /// could not be added.
    private(set) var notice: PillDisplay.Notice?

    /// What a suggestion's buttons are called back with.
    enum ActionID {
        static let add = "add"
        static let addEverywhere = "add-everywhere"
        static let notNow = "not-now"
        static let dontSuggest = "dont-suggest"
    }

    /// What the coordinator reads from the rest of the app.
    struct Inputs {
        /// The session's state, for whether a dictation is under way.
        var session: @MainActor () -> SessionState
        /// Whether a Hold to Talk key is down.
        var holdIsDown: @MainActor () -> Bool
        /// Whether Accessibility is trusted, as last read.
        var accessibilityTrusted: @MainActor () -> Bool
    }

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let dictionary: DictionaryLibrary
    @ObservationIgnored private let engine: any CorrectionEngine
    @ObservationIgnored private let clock: any SessionClock
    @ObservationIgnored private var inputs: Inputs
    @ObservationIgnored private var watcher: (any CorrectionWatching)?

    /// What was noted when each dictation started, until it leaves the session.
    private struct Dictation {
        let generation: UInt64
        let revision: UInt64
        let app: DictionaryApp?
        var anchor: WatchAnchor?
    }

    /// The dictation being watched: its audio's id and the app it went to.
    private struct Watched {
        let correctionID: UInt64
        let app: DictionaryApp?
    }

    /// The suggestion on the pill.
    private struct Shown {
        let gateID: UUID
        let noticeID: UInt64
        let app: DictionaryApp?
    }

    @ObservationIgnored private var dictations: [DictationID: Dictation] = [:]
    @ObservationIgnored private var watched: Watched?
    @ObservationIgnored private var check: Task<Void, Never>?
    @ObservationIgnored private var gate = SuggestionPresentationGate()
    @ObservationIgnored private var shown: Shown?
    @ObservationIgnored private var noticeIDs = AppNoticeID()
    @ObservationIgnored private var expiry: Task<Void, Never>?

    /// `makeWatcher` builds the watch with the coordinator's own callbacks.
    init(settings: SettingsStore, dictionary: DictionaryLibrary, engine: any CorrectionEngine, clock: any SessionClock,
         inputs: Inputs,
         makeWatcher: (_ onEdit: @escaping @MainActor @Sendable (CorrectionEdit, Bool, UInt64) -> Void,
                       _ onAbandon: @escaping @MainActor @Sendable () -> Void) -> any CorrectionWatching) {
        self.settings = settings
        self.dictionary = dictionary
        self.engine = engine
        self.clock = clock
        self.inputs = inputs
        watcher = makeWatcher({ [weak self] edit, isLast, watch in self?.edited(edit, isLast: isLast, watch: watch) },
                              { [weak self] in self?.abandoned() })
    }

    // MARK: - A dictation's life

    /// A dictation started recording, into `app`. Called when the session reads the app in front, which it does
    /// once, as the dictation starts.
    func dictationStarted(_ id: DictationID, app: AppIdentity?) {
        withdraw()
        stopCorrectionWork()
        guard let watcher else { return }
        dictations[id] = Dictation(generation: watcher.currentGeneration, revision: dictionary.revision,
                                   app: app.flatMap { DictionaryApp(id: $0.bundleID, name: $0.name) })
    }

    /// A shortcut was pressed. A recording press withdraws a visible suggestion even before anything starts.
    func triggerArrived(_ trigger: TriggerEvent) {
        switch trigger {
        case .holdPressed, .togglePressed: withdraw()
        default: break
        }
    }

    /// The session's insertion hook: the text is composed and about to be pasted to `destination`. Opens the
    /// destination's token and binds it to a watch for this dictation.
    func willInsert(_ id: DictationID, destination: InsertionDestination) {
        guard settings.correctionSuggestions, let watcher, var dictation = dictations[id],
              case .cursor(_, let token) = destination, let field = PreparedField.from(token) else { return }
        dictation.anchor = watcher.anchor(field, expecting: dictation.generation)
        dictations[id] = dictation
    }

    /// The dictation left the session. Starts the watch if it is eligible; otherwise releases its audio.
    func dictationCompleted(_ completion: DictationCompletion) {
        let dictation = dictations.removeValue(forKey: completion.id)
        guard let correctionID = completion.speech?.correctionID else { return }
        guard case .insertion(.inserted) = completion.ending, let processed = completion.processed,
              let dictation, let anchor = dictation.anchor, let watcher,
              CorrectionEligibility.isEligible(
                  suggestionsEnabled: settings.correctionSuggestions, retained: true,
                  snapshotRevision: dictation.revision, currentRevision: dictionary.revision,
                  watchGeneration: anchor.generation, currentGeneration: watcher.currentGeneration,
                  usedMacro: processed.usedMacro, pressesEnter: processed.pressEnter, output: processed.text)
        else {
            engine.releaseCorrection(correctionID)
            return
        }
        if let earlier = watched, earlier.correctionID != correctionID { engine.releaseCorrection(earlier.correctionID) }
        watched = Watched(correctionID: correctionID, app: dictation.app)
        watcher.start(anchor, pasted: processed.text, correctionID: correctionID)
    }

    // MARK: - Checks

    /// Whether a suggestion may be shown now (DESIGN §3.5, "Presentation").
    private var mayPresent: Bool {
        let session = inputs.session()
        var recording = false, startPending = false
        switch session.capture {
        case .recording: recording = true
        case .starting, .awaitingPermission: startPending = true
        case .idle: break
        }
        var inserting = false
        if case .inserting = session.output { inserting = true }
        return CorrectionSuggestionTiming.mayPresent(
            enabled: settings.correctionSuggestions, dictionaryEditable: dictionary.canEdit, recording: recording,
            transcribing: !session.pipeline.isEmpty || inserting, startPending: startPending,
            shortcutSessionActive: inputs.holdIsDown())
    }

    /// The watch reported an edit that settled. Nothing is checked unless a suggestion could be shown, Accessibility
    /// is trusted and the dictionary has room.
    private func edited(_ edit: CorrectionEdit, isLast: Bool, watch: UInt64) {
        guard let watching = watched, watching.correctionID == edit.correctionID else { return }
        guard mayPresent, inputs.accessibilityTrusted(), dictionary.hasRoom else {
            if isLast { finishWatch() }
            return
        }
        let requestedAt = gate.withdrawals
        let work = engine.correctionCheck(typed: edit.typed, edited: edit.edited, correctionID: edit.correctionID,
                                          ignore: dictionary.ignoredKeys, isLast: isLast)
        check?.cancel()
        check = Task { [weak self] in
            let suggestion = await work()
            guard !Task.isCancelled else { return }
            self?.checked(suggestion, edit: edit, isLast: isLast, watch: watch, requestedAt: requestedAt,
                          app: watching.app)
        }
    }

    private func checked(_ suggestion: DictionarySuggestion?, edit: CorrectionEdit, isLast: Bool, watch: UInt64,
                         requestedAt: UInt64, app: DictionaryApp?) {
        if isLast && watched?.correctionID == edit.correctionID { watched = nil }
        guard let suggestion else { return }
        // A word that already applies where the dictation went needs no suggestion (DESIGN §3.6, "Suggestions").
        guard !dictionary.dictionary.applies(DictionaryKey(suggestion.word), in: app?.id),
              requestedAt == gate.withdrawals, mayPresent, let watcher, watcher.claim(watch) else { return }
        // Claiming ended the watch: nothing else can use this dictation's audio.
        engine.releaseCorrection(edit.correctionID)
        if watched?.correctionID == edit.correctionID { watched = nil }
        guard let gateID = gate.present(suggestion, requestedAt: requestedAt) else { return }
        show(suggestion, gateID: gateID, app: app)
    }

    /// The watch lost Accessibility or the field turned secure: edits already reported must not be used.
    private func abandoned() {
        check?.cancel()
        check = nil
        finishWatch()
    }

    /// The watch is over without a suggestion: its audio goes.
    private func finishWatch() {
        if let watching = watched { engine.releaseCorrection(watching.correctionID) }
        watched = nil
    }

    // MARK: - Cancelling

    /// Suggestions were turned off.
    func suggestionsTurnedOff() {
        withdraw()
        stopCorrectionWork()
        engine.discardCorrection()
    }

    /// The dictionary changed: the retained audio was decoded with an older one.
    func dictionaryChanged() {
        withdraw()
        stopCorrectionWork()
        engine.discardCorrection()
    }

    /// The Run Log was cleared: no audio of a dictation may be kept anywhere.
    func runLogCleared() {
        engine.discardCorrection()
    }

    /// The app is quitting.
    func quitting() {
        withdraw()
        stopCorrectionWork()
        engine.discardCorrection()
        watcher = nil
    }

    /// Ends the watch and the check.
    private func stopCorrectionWork() {
        watcher?.cancel()
        check?.cancel()
        check = nil
        watched = nil
    }

    // MARK: - The suggestion on the pill

    /// The session took the pill: a suggestion on it is gone, and its word with it.
    func preempt() {
        guard shown != nil || notice != nil else { return }
        gate.preempt()
        hide()
    }

    /// Voids every presentation requested so far and takes a visible suggestion away.
    private func withdraw() {
        gate.withdraw()
        if shown != nil { hide() }
    }

    private func show(_ suggestion: DictionarySuggestion, gateID: UUID, app: DictionaryApp?) {
        let id = noticeIDs.make()
        shown = Shown(gateID: gateID, noticeID: id, app: app)
        notice = PillDisplay.Notice(id: id, symbol: "character.book.closed.fill", tone: .information,
                                    text: Self.question(suggestion.word), actions: Self.actions(app: app))
        expire(after: SuggestionPresentationGate.lifetime) { [weak self] in
            guard let self, let shown = self.shown, shown.gateID == gateID else { return }
            _ = self.gate.resolve(gateID)
            self.hide()
        }
    }

    /// A word could not be added: the reason, as an error notice for as long as the session's errors stay.
    private func showRefusal(_ error: DictionaryChangeError) {
        shown = nil
        let id = noticeIDs.make()
        notice = PillDisplay.Notice(id: id, symbol: "exclamationmark.triangle.fill", tone: .error, text: error.message)
        expire(after: NoticeKind.error.lifetime) { [weak self] in
            guard let self, self.notice?.id == id else { return }
            self.hide()
        }
    }

    private func hide() {
        expiry?.cancel()
        expiry = nil
        shown = nil
        notice = nil
    }

    private func expire(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        expiry?.cancel()
        let clock = self.clock
        expiry = Task {
            do { try await clock.sleep(for: seconds) } catch { return }
            action()
        }
    }

    /// The user pressed one of a suggestion's buttons. A click on a suggestion that has gone does nothing.
    func noticeAction(_ noticeID: UInt64, action: String) {
        guard let shown, shown.noticeID == noticeID, let suggestion = gate.resolve(shown.gateID) else { return }
        hide()
        let choice: DictionarySuggestionAction
        switch action {
        case ActionID.add: choice = .add
        case ActionID.addEverywhere: choice = .addEverywhere
        case ActionID.dontSuggest: choice = .dontSuggest
        default: choice = .notNow
        }
        do {
            switch choice {
            case .add: try dictionary.add(suggestion.word, strength: suggestion.strength, to: shown.app)
            case .addEverywhere: try dictionary.add(suggestion.word, strength: suggestion.strength, to: nil)
            case .dontSuggest: try dictionary.ignore(DictionaryKey(suggestion.word))
            case .notNow: break
            }
        } catch {
            showRefusal(error)
        }
    }

    /// "Add “word” to your dictionary?"
    static func question(_ word: String) -> String {
        String(localized: "Add \u{201C}\(word)\u{201D} to your dictionary?",
               comment: "Pill notice offering to add a word the user corrected")
    }

    /// Four actions when the dictation went into an app, three when it had none (DESIGN §3.6).
    static func actions(app: DictionaryApp?) -> [PillDisplay.Notice.Action] {
        let later = PillDisplay.Notice.Action(id: ActionID.notNow, title: String(localized: "Not Now"))
        let never = PillDisplay.Notice.Action(id: ActionID.dontSuggest, title: String(localized: "Don\u{2019}t Suggest"))
        guard let app else {
            return [PillDisplay.Notice.Action(id: ActionID.add, title: String(localized: "Add"), isPrimary: true),
                    later, never]
        }
        return [PillDisplay.Notice.Action(id: ActionID.add, title: String(localized: "Add to \(app.name)"),
                                          isPrimary: true),
                PillDisplay.Notice.Action(id: ActionID.addEverywhere, title: String(localized: "Add Everywhere")),
                later, never]
    }
}
