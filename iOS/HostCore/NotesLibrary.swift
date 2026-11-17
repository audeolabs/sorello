import Foundation

/// The session core's voice note, as the Notes screens record through it: `HostSessionCore` in the app, a fake in the
/// tests (ARCHITECTURE.md, "Host app", `NotesLibrary`).
@MainActor
protocol NoteRecordingHost: AnyObject {
    /// The note the core writes into while one prepares, records or saves.
    var voiceNoteID: UUID? { get }
    var onNoteChange: (@MainActor (NoteChange) -> Void)? { get set }
    var onNoteProvisional: (@MainActor (_ noteID: UUID, _ provisional: String) -> Void)? { get set }
    func userStartNote(_ target: NoteRunTarget) -> NoteStartOutcome
    @discardableResult func stopNote() -> Bool
}

extension HostSessionCore: NoteRecordingHost {}

/// What the Notes screens show, between the vault and the session core (ARCHITECTURE.md, "Host app", `NotesLibrary`).
/// It holds note text only while the vault is unlocked; a lock saves the draft and drops it all, keeping only which note
/// is open. Nothing here logs.
@MainActor
final class NotesLibrary {
    /// How long after an edit the draft is saved at the latest.
    static let draftSaveDelay: TimeInterval = 0.75
    /// The reason iOS shows when it asks for the passcode.
    static let unlockPrompt = "Open your notes"

    private let vault: NoteVault
    private let host: NoteRecordingHost
    private let format: NoteRunFormatter
    private let after: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private(set) var state: NoteVaultState
    private(set) var canMakeVault: Bool
    private(set) var hasRecoveryCode = false
    private(set) var isUnlocking = false
    /// The vault was just made: the recovery code is offered until it is made or skipped. In memory only.
    private(set) var offersRecoveryCode = false
    /// A recovery code just made, as it shows, until the user is done with it or the vault locks.
    private(set) var recoveryCode: String?
    private(set) var query = ""
    /// The notes the query matches, newest first; for no query, every note, pinned first. Empty unless unlocked.
    private(set) var hits: [NoteSearchHit] = []
    private(set) var unreadableCount = 0
    /// The note screen's note. Kept through a lock, which drops its text.
    private(set) var openNoteID: UUID?
    private(set) var openNote: Note?
    /// The open note's text as it is edited; nil unless it is edited.
    private(set) var draft: String?
    /// The open note's provisional tail while it records with the vault unlocked.
    private(set) var provisional = ""
    /// The note the core writes into, nil when none.
    private(set) var recordingNoteID: UUID?
    /// How the open note's last recording ended, when not by the user's stop.
    private(set) var openNoteEnding: NoteEndReason?
    /// The last refusal or failure, as a content-free sentence, until dismissed.
    private(set) var message: String?
    /// Called after every change.
    var onChange: (@MainActor () -> Void)?

    private var index: NoteSearch.Index?
    /// Counts this library's locks, so an unlock asked for before one ends locked.
    private var locks = 0
    private var draftNeedsSaving = false
    private var saveScheduled = false
    /// The entry of the Notes screen that showed last, so only an entry's first showing asks for the unlock.
    private var lastEntry: UUID?

    /// `after` runs work on the main actor once a delay has passed.
    init(vault: NoteVault, host: NoteRecordingHost, format: @escaping NoteRunFormatter,
         after: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = NotesLibrary.mainAfter) {
        self.vault = vault
        self.host = host
        self.format = format
        self.after = after
        state = vault.state
        canMakeVault = vault.canMakeVault
        recordingNoteID = host.voiceNoteID
        host.onNoteChange = { [weak self] in self?.noteChanged($0) }
        refresh()
    }

    nonisolated static func mainAfter(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }

    var screen: NotesScreen {
        NotesScreen(vault: state, canMakeVault: canMakeVault, offersRecoveryCode: offersRecoveryCode)
    }

    /// The open note as it records: its text with the provisional tail at the run's place.
    var liveText: NoteLiveText? {
        guard state == .unlocked, let openNote else { return nil }
        return NoteLiveText(note: openNote, provisional: provisional, format: format)
    }

    /// Whether the core's provisional tail is wanted: the open note records and the vault is unlocked.
    var listensForProvisional: Bool {
        state == .unlocked && openNoteID != nil && openNoteID == recordingNoteID
    }

    // MARK: Vault

    func makeVault() {
        do {
            try vault.makeVault()
            offersRecoveryCode = true
        } catch {
            fail(error)
        }
        refresh()
    }

    /// Asks the user to authenticate, off the main thread. A lock meanwhile wins.
    func unlock() {
        guard state == .locked, !isUnlocking else { return }
        isUnlocking = true
        onChange?()
        let vault = vault, prompt = Self.unlockPrompt, issued = locks
        Task { [weak self] in
            let failure: Error? = await Task.detached {
                do {
                    try vault.unlock(prompt: prompt)
                    return nil
                } catch {
                    return error
                }
            }.value
            self?.unlockEnded(failure, issued: issued)
        }
    }

    private func unlockEnded(_ failure: Error?, issued: Int) {
        isUnlocking = false
        // A lock after the request, even one before the authentication began, wins.
        if locks != issued { vault.lock() }
        // The user's cancel and a lock that won need no sentence.
        if let failure, failure as? NoteError != .authenticationCancelled, failure as? NoteError != .locked {
            fail(failure)
        }
        refresh()
    }

    /// The Notes screen shows itself. `entry` is new each time it is entered from Home and the same at every showing
    /// until the user goes back there; an entry's first showing asks for the unlock when the vault is locked.
    func appeared(entry: UUID) {
        guard entry != lastEntry else { return }
        lastEntry = entry
        unlock()
    }

    /// Saves the draft, locks the vault and drops every note's text. A recording goes on.
    func lock() {
        saveDraft()
        locks += 1
        vault.lock()
        refresh()
    }

    /// Reads the vault's state again, as when the app becomes active: a passcode set in Settings meanwhile counts.
    func refreshState() {
        refresh()
    }

    func makeRecoveryCode() {
        do {
            recoveryCode = try vault.makeRecoveryCode().displayText
            offersRecoveryCode = false
        } catch {
            fail(error)
        }
        refresh()
    }

    func skipRecoveryCode() {
        offersRecoveryCode = false
        onChange?()
    }

    func doneWithRecoveryCode() {
        recoveryCode = nil
        onChange?()
    }

    /// With notes but no secret: the recovery code puts the secret back and unlocks.
    func restore(recoveryCode text: String) {
        do {
            try vault.restore(recoveryCode: text)
        } catch {
            fail(error)
        }
        refresh()
    }

    /// Erases every note. Refused while a note records.
    func eraseAll() {
        do {
            try vault.eraseAll()
            openNoteID = nil
            offersRecoveryCode = false
        } catch {
            fail(error)
        }
        refresh()
    }

    func dismissMessage() {
        message = nil
        onChange?()
    }

    // MARK: List

    func search(_ query: String) {
        guard state == .unlocked else { return }
        self.query = query
        hits = index.map { listed(in: $0) } ?? []
        onChange?()
    }

    /// Pins or unpins a note of the list. Refused while it records.
    func setPinned(_ pinned: Bool, of id: UUID) {
        guard state == .unlocked else { return }
        do {
            guard id != recordingNoteID else { throw NoteError.noteIsRecording }
            try vault.setPinned(pinned, of: id)
        } catch {
            fail(error)
        }
        refresh()
    }

    /// Deletes a note; the open note closes with it. Refused while it records.
    func delete(_ id: UUID) {
        guard state == .unlocked else { return }
        do {
            guard id != recordingNoteID else { throw NoteError.noteIsRecording }
            try vault.deleteNote(id)
            if openNoteID == id { openNoteID = nil }
        } catch {
            fail(error)
        }
        refresh()
    }

    /// Record from the Notes screen: a new note, opened when the vault is unlocked.
    func record() {
        let outcome = host.userStartNote(.newNote)
        if let sentence = outcome.message { message = sentence }
        if outcome == .started, state == .unlocked, let id = host.voiceNoteID {
            open(id)
        } else {
            onChange?()
        }
    }

    /// Stops the note in progress, wherever it started. Never needs an unlock.
    func stop() {
        host.stopNote()
        onChange?()
    }

    // MARK: Note

    /// Opens a note. The open note's draft is saved first; one that cannot be saved stays open.
    func open(_ id: UUID) {
        guard openNoteID == id || saveDraft() else { return }
        openNoteID = id
        openNote = nil
        draft = nil
        draftNeedsSaving = false
        openNoteEnding = nil
        refresh()
    }

    /// Leaves the note screen: the draft is saved first; one that cannot be saved stays open.
    func close() {
        guard openNoteID != nil, saveDraft() else { return }
        openNoteID = nil
        refresh()
    }

    /// An edit to the open note's text, saved within `draftSaveDelay`.
    func edit(_ text: String) {
        guard state == .unlocked, openNoteID != nil, let draft, text != draft else { return }
        self.draft = text
        draftNeedsSaving = true
        if !saveScheduled {
            saveScheduled = true
            after(Self.draftSaveDelay) { [weak self] in
                self?.saveScheduled = false
                self?.saveDraft()
            }
        }
        onChange?()
    }

    /// Saves the draft if it changed. False if it could not be saved.
    @discardableResult
    func saveDraft() -> Bool {
        guard draftNeedsSaving, let id = openNoteID, let draft, state == .unlocked else { return true }
        do {
            try vault.replaceText(of: id, with: draft)
            draftNeedsSaving = false
        } catch {
            fail(error)
            onChange?()
            return false
        }
        refresh()
        return true
    }

    /// Resume: saves the draft, then records into the open note at `place` (`NoteCursor`).
    func resume(at place: NoteRunPlace) {
        guard state == .unlocked, let id = openNoteID, saveDraft() else { return }
        let outcome = host.userStartNote(.note(id, at: place))
        if let sentence = outcome.message { message = sentence }
        onChange?()
    }

    /// Deletes the open note and closes it. Refused while it records.
    func deleteOpenNote() {
        guard let id = openNoteID else { return }
        delete(id)
    }

    // MARK: The core's note

    private func noteChanged(_ change: NoteChange) {
        switch change {
        case .started(let id):
            recordingNoteID = id
            if id == openNoteID {
                draft = nil
                draftNeedsSaving = false
                openNoteEnding = nil
            }
        case .wrote(let id):
            // The next report's tail follows at once.
            if id == openNoteID { provisional = "" }
        case .ended(let id, let reason):
            if recordingNoteID == id { recordingNoteID = nil }
            if id == openNoteID { openNoteEnding = reason.message == nil ? nil : reason }
            if state == .unlocked {
                do {
                    try vault.mergePendingRuns()
                } catch {
                    fail(error)
                }
            }
            refresh()
            // The open note's screen says how it ended; otherwise Notes says it.
            if let sentence = reason.message, openNoteID != id {
                message = sentence
                onChange?()
            }
            return
        }
        refresh()
    }

    private func noteProvisional(_ id: UUID, _ text: String) {
        guard listensForProvisional, id == openNoteID else { return }
        provisional = text
        onChange?()
    }

    // MARK: State

    /// Reads the vault's state; unlocked, takes a new listing and re-reads the open note, and locked, drops every
    /// note's text.
    private func refresh() {
        state = vault.state
        canMakeVault = vault.canMakeVault
        if state == .unlocked {
            hasRecoveryCode = vault.hasRecoveryCode
            reload()
        } else {
            dropText()
            // Only an unlock opens the note again; with no secret or no vault there is none.
            if state != .locked { openNoteID = nil }
        }
        if listensForProvisional {
            if host.onNoteProvisional == nil {
                host.onNoteProvisional = { [weak self] in self?.noteProvisional($0, $1) }
            }
        } else {
            host.onNoteProvisional = nil
            provisional = ""
        }
        onChange?()
    }

    private func reload() {
        do {
            let index = try vault.searchIndex()
            self.index = index
            hits = listed(in: index)
            unreadableCount = try vault.unreadableNoteCount()
        } catch {
            fail(error)
        }
        guard let id = openNoteID else {
            openNote = nil
            draft = nil
            return
        }
        do {
            let note = try vault.note(id)
            openNote = note
            if note.isRecording {
                draft = nil
            } else if draft == nil {
                draft = note.text
            }
        } catch NoteError.noSuchNote {
            // Its screen goes, so how it ended is said on Notes.
            if let sentence = openNoteEnding?.message { message = sentence }
            openNoteEnding = nil
            openNoteID = nil
            openNote = nil
            draft = nil
            draftNeedsSaving = false
        } catch {
            fail(error)
        }
    }

    /// The list: the query's hits, newest first, or with no query every note, pinned first.
    private func listed(in index: NoteSearch.Index) -> [NoteSearchHit] {
        query.isEmpty ? index.listing : index.search(query)
    }

    private func dropText() {
        index = nil
        hits = []
        query = ""
        unreadableCount = 0
        openNote = nil
        draft = nil
        draftNeedsSaving = false
        provisional = ""
        recoveryCode = nil
    }

    private func fail(_ error: Error) {
        message = (error as? NoteError ?? .storageFailed).message
    }
}
