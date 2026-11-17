import CryptoKit
import Foundation

/// Why a notes call failed. Content-free.
enum NoteError: Error, Equatable {
    /// Making a vault needs a device passcode.
    case noPasscode
    case vaultExists
    case noVault
    /// The notes directory holds a vault but the key store has no secret.
    case secretMissing
    case locked
    case authenticationCancelled
    case keyStoreFailed
    /// A file could not be read, as while the iPhone is locked.
    case unavailable
    case storageFailed
    case noRecoveryCode
    case malformedRecoveryCode
    case wrongRecoveryCode
    case noSuchNote
    case noteIsRecording
    case runEnded
}

/// Why the key store failed. Content-free.
enum NoteKeyStoreError: Error, Equatable {
    case notFound
    case cancelled
    case failed
}

/// The port to where the vault secret lives (ARCHITECTURE.md, "Notes", Key store): the Keychain in the app
/// (`KeychainNoteKeyStore`), a fake in the tests.
protocol NoteKeyStore: AnyObject {
    /// Whether the iPhone has a passcode, so a secret can be kept behind it.
    var deviceHasPasscode: Bool { get }
    /// Whether a secret is stored. Never asks the user to authenticate.
    func hasSecret() -> Bool
    /// Stores `secret`, replacing any.
    func storeSecret(_ secret: Data) throws
    /// The secret, after the user authenticates with `prompt` as the reason. Blocks until they do.
    func readSecret(prompt: String) throws -> Data
    /// Deletes the secret. No secret is not an error.
    func deleteSecret() throws
}

/// The vault's states (ARCHITECTURE.md, "Notes", States).
enum NoteVaultState: Equatable {
    case noVault
    case locked
    case unlocked
    case secretMissing
}

/// A note's body, sealed in its `body` record. Part of the stored format.
struct NoteBody: Codable, Equatable {
    static let schema = 1
    var schema = NoteBody.schema
    var text: String
    var created: Date
    var modified: Date
    /// The runs merged into this body whose files may remain, so a crash between the write and their removal
    /// never merges one twice.
    var mergedRuns: [UUID]
}

/// The vault and, while it is unlocked, the library (ARCHITECTURE.md, "Notes", Vault and Library and search).
/// Thread-safe; `unlock` blocks while the user authenticates, so it is called off the main thread.
final class NoteVault: @unchecked Sendable {
    private struct Unlocked {
        var privateKey: Curve25519.KeyAgreement.PrivateKey
        var secret: Data
        /// Every note whose body opened.
        var bodies: [UUID: NoteBody]
        /// Notes whose body did not open: left as they are.
        var unreadable: Set<UUID>
    }

    private let storage: NoteStorage
    private let keyStore: NoteKeyStore
    private let format: NoteRunFormatter
    private let now: () -> Date
    private let mutex = NSLock()
    private var unlocked: Unlocked?
    /// Counts locks, so an unlock that waited on the user while the vault was locked ends locked.
    private var lockCount = 0

    init(storage: NoteStorage, keyStore: NoteKeyStore, formatRun: @escaping NoteRunFormatter,
         now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.keyStore = keyStore
        self.format = formatRun
        self.now = now
    }

    // MARK: State

    var state: NoteVaultState {
        if mutex.withLock({ unlocked != nil }) { return .unlocked }
        if keyStore.hasSecret() { return .locked }
        return storage.holdsVault ? .secretMissing : .noVault
    }

    /// Whether a vault can be made: there is none, and the iPhone has a passcode.
    var canMakeVault: Bool { state == .noVault && keyStore.deviceHasPasscode }

    /// Makes a vault: stores a new secret, writes the public key, and leaves the vault unlocked with no notes.
    func makeVault() throws {
        guard keyStore.deviceHasPasscode else { throw NoteError.noPasscode }
        guard state == .noVault else { throw NoteError.vaultExists }
        let secret = NoteVaultKeys.makeSecret()
        guard let privateKey = NoteVaultKeys.privateKey(for: secret) else { throw NoteError.keyStoreFailed }
        do {
            try keyStore.storeSecret(secret)
        } catch {
            throw NoteError.keyStoreFailed
        }
        try storage.writePublicKey(privateKey.publicKey.rawRepresentation)
        mutex.withLock { unlocked = Unlocked(privateKey: privateKey, secret: secret, bodies: [:], unreadable: []) }
    }

    /// Unlocks: reads the secret through the key store, so the user authenticates, then opens the notes and merges
    /// the pending runs. A lock while the user authenticates wins.
    func unlock(prompt: String) throws {
        let locks = mutex.withLock { unlocked == nil ? lockCount : nil }
        guard let locks else { return }
        let secret: Data
        do {
            secret = try keyStore.readSecret(prompt: prompt)
        } catch NoteKeyStoreError.cancelled {
            throw NoteError.authenticationCancelled
        } catch NoteKeyStoreError.notFound {
            throw storage.holdsVault ? NoteError.secretMissing : NoteError.noVault
        } catch {
            throw NoteError.keyStoreFailed
        }
        guard let privateKey = NoteVaultKeys.privateKey(for: secret) else { throw NoteError.keyStoreFailed }
        try open(secret: secret, privateKey: privateKey, unlessLockedSince: locks)
    }

    /// Locks: drops the secret, the private key and every opened note.
    func lock() {
        mutex.withLock {
            unlocked = nil
            lockCount += 1
        }
    }

    // MARK: Recovery code

    var hasRecoveryCode: Bool { storage.readRecoveryWrap() != .absent }

    /// Makes a new recovery code, which replaces any earlier one. Needs the vault unlocked.
    func makeRecoveryCode() throws -> NoteRecoveryCode {
        try mutex.withLock {
            guard let unlocked else { throw NoteError.locked }
            let code = NoteRecoveryCode.make()
            try storage.writeRecoveryWrap(try code.wrap(unlocked.secret))
            return code
        }
    }

    /// Restores the secret from a recovery code when the key store has none, and leaves the vault unlocked. A wrong
    /// or malformed code changes nothing.
    func restore(recoveryCode text: String) throws {
        guard state == .secretMissing else { throw state == .noVault ? NoteError.noVault : NoteError.vaultExists }
        guard let code = NoteRecoveryCode(text) else { throw NoteError.malformedRecoveryCode }
        let wrap: Data
        switch storage.readRecoveryWrap() {
        case .absent: throw NoteError.noRecoveryCode
        case .unreadable: throw NoteError.unavailable
        case .data(let data): wrap = data
        }
        guard let secret = code.unwrap(wrap), let privateKey = NoteVaultKeys.privateKey(for: secret) else {
            throw NoteError.wrongRecoveryCode
        }
        if case .data(let stored) = storage.readPublicKey(), stored != privateKey.publicKey.rawRepresentation {
            throw NoteError.wrongRecoveryCode
        }
        guard keyStore.deviceHasPasscode else { throw NoteError.noPasscode }
        do {
            try keyStore.storeSecret(secret)
        } catch {
            throw NoteError.keyStoreFailed
        }
        let locks = mutex.withLock { lockCount }
        try open(secret: secret, privateKey: privateKey, unlessLockedSince: locks)
    }

    /// Erases every note: deletes the secret, then the notes directory. Refused while a run records, and no run
    /// begins until it is done.
    func eraseAll() throws {
        try storage.erase {
            lock()
            do {
                try keyStore.deleteSecret()
            } catch {
                throw NoteError.keyStoreFailed
            }
        }
    }

    // MARK: Library

    /// Every note, newest first.
    func notes() throws -> [Note] {
        try withUnlocked { unlocked in
            storage.noteIDs().compactMap { note($0, in: unlocked) }.sorted(by: Note.isNewer)
        }
    }

    /// One note.
    func note(_ id: UUID) throws -> Note {
        try withUnlocked { unlocked in
            guard let note = note(id, in: unlocked) else { throw NoteError.noSuchNote }
            return note
        }
    }

    /// Notes that hold a body that does not open, left as they are.
    func unreadableNoteCount() throws -> Int {
        try withUnlocked { $0.unreadable.count }
    }

    /// The notes in which every term of `query` matches, newest first ([NoteSearch]).
    func search(_ query: String) throws -> [NoteSearchHit] {
        NoteSearch.search(query, in: try notes())
    }

    /// Merges every run that is not recording into its note. Does nothing while the vault is locked.
    func mergePendingRuns() throws {
        mutex.lock()
        defer { mutex.unlock() }
        guard var unlocked else { return }
        defer { self.unlocked = unlocked }
        for id in storage.noteIDs() {
            try merge(id, in: &unlocked)
        }
    }

    /// Replaces a note's text; its pending runs count as replaced. Refused while it records.
    func replaceText(of id: UUID, with text: String) throws {
        try withUnlockedMutating { unlocked in
            guard let current = note(id, in: unlocked) else { throw NoteError.noSuchNote }
            // One listing decides both: a run that begins after it is not counted as replaced.
            let runs = storage.runs(of: id)
            guard !runs.contains(where: \.isRecording) else { throw NoteError.noteIsRecording }
            let body = NoteBody(text: text, created: current.created, modified: now(), mergedRuns: runs.map(\.id))
            try write(body, of: id, with: unlocked.privateKey.publicKey)
            unlocked.bodies[id] = body
            for run in runs { storage.removeRun(run.id, order: run.order, of: id) }
        }
    }

    /// Deletes a note. Refused while it records.
    func deleteNote(_ id: UUID) throws {
        try withUnlockedMutating { unlocked in
            guard note(id, in: unlocked) != nil else { throw NoteError.noSuchNote }
            try storage.deleteNote(id)
            unlocked.bodies[id] = nil
        }
    }

    // MARK: Opening

    private func open(secret: Data, privateKey: Curve25519.KeyAgreement.PrivateKey, unlessLockedSince locks: Int) throws {
        let publicKey = privateKey.publicKey.rawRepresentation
        if storage.readPublicKey() != .data(publicKey) {
            try storage.writePublicKey(publicKey)
        }
        mutex.lock()
        defer { mutex.unlock() }
        guard lockCount == locks else { throw NoteError.locked }
        guard unlocked == nil else { return }
        storage.removeLeftovers()
        var opened = Unlocked(privateKey: privateKey, secret: secret, bodies: [:], unreadable: [])
        for id in storage.noteIDs() {
            switch storage.readBody(of: id) {
            case .absent: break
            case .unreadable: opened.unreadable.insert(id)
            case .data(let record):
                if let body = openBody(record, of: id, with: privateKey) {
                    opened.bodies[id] = body
                } else {
                    opened.unreadable.insert(id)
                }
            }
        }
        for id in storage.noteIDs() {
            try? merge(id, in: &opened)
        }
        unlocked = opened
    }

    private func openBody(_ record: Data, of id: UUID, with privateKey: Curve25519.KeyAgreement.PrivateKey) -> NoteBody? {
        guard let plaintext = NoteSealing.open(record, as: .body(id), with: privateKey),
              let body = NoteCoding.decode(NoteBody.self, from: plaintext), body.schema == NoteBody.schema
        else { return nil }
        return body
    }

    private func write(_ body: NoteBody, of id: UUID, with publicKey: Curve25519.KeyAgreement.PublicKey) throws {
        let record: Data
        do {
            record = try NoteSealing.seal(try NoteCoding.encode(body), as: .body(id), to: publicKey)
        } catch {
            throw NoteError.storageFailed
        }
        try storage.writeBody(record, of: id)
    }

    // MARK: Runs

    private func pendingRuns(of id: UUID, mergedInto body: NoteBody?,
                             with privateKey: Curve25519.KeyAgreement.PrivateKey) -> [NotePendingRun] {
        let merged = Set(body?.mergedRuns ?? [])
        return storage.runs(of: id).filter { !merged.contains($0.id) }.map { run in
            let start = run.start
                .flatMap { NoteSealing.open($0, as: .runStart(id, run: run.id), with: privateKey) }
                .flatMap { NoteCoding.decode(NoteRunStart.self, from: $0) }
                .flatMap { $0.schema == NoteRunStart.schema ? $0 : nil }
            let pieces = run.segments.compactMap { segment in
                NoteSealing.open(segment.record, as: .segment(id, run: run.id, sequence: segment.sequence), with: privateKey)
                    .map { String(decoding: $0, as: UTF8.self) }
            }
            return NotePendingRun(id: run.id, place: start?.place ?? .end, startedAt: start?.startedAt, pieces: pieces,
                                  isRecording: run.isRecording)
        }
    }

    /// The note as it shows, or nil if it has no body and no pending run, or its body does not open.
    private func note(_ id: UUID, in unlocked: Unlocked) -> Note? {
        guard !unlocked.unreadable.contains(id) else { return nil }
        let body = unlocked.bodies[id]
        let runs = pendingRuns(of: id, mergedInto: body, with: unlocked.privateKey)
        guard body != nil || !runs.isEmpty else { return nil }
        let starts = runs.compactMap(\.startedAt)
        let created = body?.created ?? starts.min() ?? now()
        let modified = ([body?.modified].compactMap { $0 } + starts).max() ?? created
        let text = NoteMerge.merge(runs.map { NoteRunContent(place: $0.place, pieces: $0.pieces) },
                                   into: body?.text ?? "", format: format)
        return Note(id: id, text: text, body: body?.text ?? "", created: created, modified: modified, pendingRuns: runs)
    }

    /// Merges the runs of note `id` that have ended, up to the first that records, into its body, then removes their
    /// files. A run already named by the body is only removed. A new note whose runs hold no text is removed.
    private func merge(_ id: UUID, in unlocked: inout Unlocked) throws {
        guard !unlocked.unreadable.contains(id) else { return }
        let stored = storage.runs(of: id)
        let body = unlocked.bodies[id]
        let alreadyMerged = Set(body?.mergedRuns ?? [])
        // The ended runs before the first that records, so the order of the runs never changes.
        let pending = Array(pendingRuns(of: id, mergedInto: body, with: unlocked.privateKey).prefix { !$0.isRecording })
        if !pending.isEmpty {
            let text = NoteMerge.merge(pending.map { NoteRunContent(place: $0.place, pieces: $0.pieces) },
                                       into: body?.text ?? "", format: format)
            if body != nil || !text.isEmpty {
                let starts = pending.compactMap(\.startedAt)
                let created = body?.created ?? starts.min() ?? now()
                let modified = ([body?.modified].compactMap { $0 } + starts).max() ?? created
                let remaining = stored.map(\.id).filter { alreadyMerged.contains($0) }
                let merged = NoteBody(text: text, created: created, modified: modified,
                                      mergedRuns: remaining + pending.map(\.id))
                try write(merged, of: id, with: unlocked.privateKey.publicKey)
                unlocked.bodies[id] = merged
            }
        }
        let removable = Set(pending.map(\.id)).union(alreadyMerged)
        for run in stored where removable.contains(run.id) && !run.isRecording {
            storage.removeRun(run.id, order: run.order, of: id)
        }
        if unlocked.bodies[id] == nil {
            storage.removeNoteIfEmpty(id)
        }
    }

    // MARK: Locking

    private func withUnlocked<T>(_ body: (Unlocked) throws -> T) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }
        guard let unlocked else { throw NoteError.locked }
        return try body(unlocked)
    }

    private func withUnlockedMutating<T>(_ body: (inout Unlocked) throws -> T) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }
        guard var unlocked else { throw NoteError.locked }
        defer { self.unlocked = unlocked }
        return try body(&unlocked)
    }
}
