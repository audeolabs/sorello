import DictionaryKit
import Foundation

/// Words from corrections (ARCHITECTURE.md, "Custom dictionary", Words from corrections): what the host keeps of the
/// newest streamed dictation for a correction, and the word the keyboard hands over in `added-word.json`, taken,
/// decided and saved through `DictionaryLibrary`. Its outcome is published in the status for `addedWordTTL`.
///
/// - **What is kept.** The newest dictation's request id, the engine's correction id and the text written to its
///   result, in memory only, beside what the engine keeps. `releaseAll` lets all of it go (a new recording, the
///   session's end, a lock, a dictionary edit, the runtime's release); deciding a word releases only its own
///   dictation's.
/// - **Take.** One rename to a private staging name, then the private copy is read and judged, so what is decided is
///   always the version taken. A copy that cannot be read yet (locked) is held under its private name and read again
///   at the next take, until `addedWordTTL` after its modification date. A copy that was read is deleted before the
///   word is decided, so a word is acted on at most once.
/// - **Decision**, one word at a time, in the contract's order; the save is decided again against the library as it
///   is, in the same main-actor turn as the save.
@MainActor
final class AddedWordInbox {
    struct Kept: Equatable, Sendable {
        var requestID: UUID
        var correctionID: UInt64
        var text: String
    }

    /// How long the engine keeps a dictation for a correction (DESIGN §3.4): the host's record of it goes then too.
    static let keptLifetime: TimeInterval = 90

    private let store: SharedDictationStore
    private let library: DictionaryLibrary
    private let verifier: CorrectionVerifying
    private let now: @MainActor () -> Date
    /// A clock no one sets (the system's uptime in the app), so a clock change never stretches what is kept.
    private let uptime: @MainActor () -> TimeInterval

    /// The newest dictation kept for a correction, nil when none.
    private(set) var kept: Kept?
    /// When `kept` goes, as the engine's copy does, on `uptime`'s clock.
    private var keptUntil: TimeInterval?
    /// The last outcome; published while fresh (`status(now:)`).
    private(set) var outcome: AddedWordStatus?
    /// A taken copy that could not be read yet (the device is locked).
    private var held: SharedDictationStore.TakenAddedWord?
    /// Words taken while another is decided, oldest first.
    private var queue: [AddedWord] = []
    /// A word is being decided (its check may take a while).
    private(set) var isDeciding = false
    /// An outcome was decided: the status should be published again.
    var onOutcome: (@MainActor () -> Void)?

    init(store: SharedDictationStore, library: DictionaryLibrary, verifier: CorrectionVerifying,
         now: @escaping @MainActor () -> Date,
         uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store
        self.library = library
        self.verifier = verifier
        self.now = now
        self.uptime = uptime
    }

    // MARK: What is kept

    /// A dictation was written to its result with a correction id: it is the newest, so it replaces what was kept.
    func keep(requestID: UUID, correctionID: UInt64, text: String) {
        kept = Kept(requestID: requestID, correctionID: correctionID, text: text)
        keptUntil = uptime() + Self.keptLifetime
    }

    /// On every tick: the record goes once the engine's copy has expired.
    func expire() {
        guard let keptUntil else { return }
        if uptime() >= keptUntil { forgetKept() }
    }

    private func forgetKept() {
        kept = nil
        keptUntil = nil
    }

    /// Releases everything kept, here and in the engine.
    func releaseAll() {
        forgetKept()
        verifier.discardCorrection()
    }

    // MARK: Status

    /// The last outcome until `addedWordTTL` after it was decided.
    func status(now: Date) -> AddedWordStatus? {
        guard let outcome, DictationProtocol.isFresh(outcome.decidedAt, ttl: DictationProtocol.addedWordTTL, now: now)
        else { return nil }
        return outcome
    }

    // MARK: Take

    /// Takes `added-word.json` (on `.addedWord`, every heartbeat while live, launch, foreground, session end).
    func take() {
        let now = self.now()
        if let held {
            switch store.readTaken(held) {
            case .absent:
                self.held = nil
            case .value(let word):
                store.removeTaken(held)
                self.held = nil
                accept(word, now: now)
            case .incompatible:
                store.removeTaken(held)
                self.held = nil
            case .unreadable:
                // Still locked: a newer file is unreadable as well, so it waits where it is.
                guard isExpiredUnread(held, now: now) else { return }
                store.removeTaken(held)
                self.held = nil
            }
        }
        guard let taken = store.takeAddedWord() else { return }
        switch store.readTaken(taken) {
        case .absent:
            break
        case .value(let word):
            store.removeTaken(taken)
            accept(word, now: now)
        case .incompatible:
            store.removeTaken(taken)
        case .unreadable:
            if isExpiredUnread(taken, now: now) { store.removeTaken(taken) } else { held = taken }
        }
    }

    private func isExpiredUnread(_ taken: SharedDictationStore.TakenAddedWord, now: Date) -> Bool {
        guard let modified = store.modificationDate(of: taken) else { return true }
        return !DictationProtocol.isFresh(modified, ttl: DictationProtocol.addedWordTTL, now: now)
    }

    /// A copy that was read: fresh and well formed, it is decided; otherwise ignored (it is deleted already). How many
    /// words the range holds is judged against the kept text, in the decision.
    private func accept(_ word: AddedWord, now: Date) {
        guard DictationProtocol.isFresh(word.issuedAt, ttl: DictationProtocol.addedWordTTL, now: now),
              !word.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              word.replacedStart >= 0, word.replacedStart < word.replacedEnd else { return }
        queue.append(word)
        decideNext()
    }

    // MARK: Decision

    private func decideNext() {
        guard !isDeciding, !queue.isEmpty else { return }
        let word = queue.removeFirst()
        isDeciding = true
        Task { [weak self] in
            await self?.decide(word)
            self?.isDeciding = false
            self?.decideNext()
        }
    }

    /// What the check of step 3 found.
    private enum Check {
        case heard(strength: Float)
        case notHeard
        /// Step 4: no check, or one that decided nothing.
        case undecided
    }

    private func decide(_ word: AddedWord) async {
        // 1. The dictionary cannot take it.
        guard library.canEdit, !library.isFull,
              let entry = library.validatedEntry(text: word.word, strength: DictionaryValidation.defaultStrength) else {
            return publish(word, .notAdded)
        }
        // 2. Its key is there already.
        if library.contains(entry.key) { return publish(word, .alreadyInDictionary) }
        let check = await self.check(word)
        if case .notHeard = check { return publish(word, .notHeard) }
        let strength: Float
        if case .heard(let found) = check { strength = found } else { strength = DictionaryValidation.defaultStrength }
        // The check took time: the save is decided again against the library as it is now, in this turn.
        guard library.canEdit, !library.isFull else { return publish(word, .notAdded) }
        if library.contains(entry.key) { return publish(word, .alreadyInDictionary) }
        guard library.save(text: entry.text, strength: strength, replacing: nil) == nil else {
            return publish(word, .notAdded)
        }
        publish(word, .added, strength: strength)
    }

    /// 3. With its own dictation kept, and the range fitting the kept text, the engine checks the correction. That
    /// dictation is released afterwards, never a newer one.
    private func check(_ word: AddedWord) async -> Check {
        expire()
        guard let kept, kept.requestID == word.requestID else { return .undecided }
        let correctionID = kept.correctionID
        defer {
            verifier.releaseCorrection(correctionID)
            if self.kept?.correctionID == correctionID { forgetKept() }
        }
        guard let edited = CorrectionOffer.replacing(word.replacedStart..<word.replacedEnd, in: kept.text,
                                                     with: word.word) else { return .undecided }
        switch await verifier.verifyCorrection(typed: kept.text, edited: edited, correctionID: correctionID) {
        case .verified(let suggestion): return .heard(strength: suggestion.strength)
        case .notRecognized: return .notHeard
        case .unverified: return .undecided
        }
    }

    private func publish(_ word: AddedWord, _ outcome: AddedWordStatus.Outcome, strength: Float? = nil) {
        self.outcome = AddedWordStatus(id: word.id, outcome: outcome, strength: strength, decidedAt: now())
        onOutcome?()
    }
}
