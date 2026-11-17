import Foundation

/// What a run records into: a new note, or an existing one at a place in its text.
enum NoteRunTarget: Equatable {
    case newNote
    case note(UUID, at: NoteRunPlace)
}

/// The start of a run, sealed in its `start` record. Part of the stored format.
struct NoteRunStart: Codable, Equatable {
    static let schema = 1
    var schema = NoteRunStart.schema
    /// A UTF-16 offset, or nil for the end.
    var offset: Int?
    var startedAt: Date

    var place: NoteRunPlace { offset.map(NoteRunPlace.offset) ?? .end }
}

/// The recording side of notes (ARCHITECTURE.md, "Notes", Recording side). It needs only the storage, so a run
/// begins and writes while the vault, and the iPhone, are locked; nothing it writes can be read without the
/// vault's secret.
final class NoteRecorder {
    private let storage: NoteStorage
    private let now: () -> Date

    init(storage: NoteStorage, now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.now = now
    }

    /// Whether a vault exists to record into: its public key can be read, so a run could begin. Reads one small file
    /// and begins nothing.
    var hasVault: Bool {
        if case .data = storage.readPublicKey() { return true }
        return false
    }

    /// Begins a run: reads the public key, makes the run's directory and writes its start. Throws `noVault` without
    /// a public key, `unavailable` if it cannot be read, `noSuchNote` for a note that is gone, and `storageFailed`.
    func beginRun(_ target: NoteRunTarget) throws -> NoteRunWriter {
        let existing: UUID?
        var start = NoteRunStart(offset: nil, startedAt: now())
        switch target {
        case .newNote:
            existing = nil
        case .note(let id, let place):
            existing = id
            if case .offset(let offset) = place { start.offset = max(0, offset) }
        }
        let run = try storage.beginRun(of: existing)
        do {
            guard let publicKey = NoteVaultKeys.publicKey(run.publicKey) else { throw NoteError.noVault }
            let sealer = try NoteRunSealer(publicKey: publicKey)
            let record = try sealer.seal(try NoteCoding.encode(start), as: .runStart(run.noteID, run: run.runID))
            try storage.writeRunFile(record, named: NoteStoredNames.runStart, run: run.runID, order: run.order,
                                     of: run.noteID)
            return NoteRunWriter(storage: storage, noteID: run.noteID, runID: run.runID, order: run.order, sealer: sealer)
        } catch {
            storage.endRun(run.runID)
            throw error as? NoteError ?? NoteError.storageFailed
        }
    }
}

/// One run that records (ARCHITECTURE.md, "Notes", Recording side): it seals each settled piece as the next
/// segment, under the run's content key, which it drops at `end`. Thread-safe.
final class NoteRunWriter: @unchecked Sendable {
    let noteID: UUID
    let runID: UUID
    private let order: Int
    private let storage: NoteStorage
    private let lock = NSLock()
    private var sealer: NoteRunSealer?
    private var lastSequence: UInt32 = 0

    fileprivate init(storage: NoteStorage, noteID: UUID, runID: UUID, order: Int, sealer: NoteRunSealer) {
        self.storage = storage
        self.noteID = noteID
        self.runID = runID
        self.order = order
        self.sealer = sealer
    }

    deinit {
        storage.endRun(runID)
    }

    /// Seals `piece` and writes it as the next segment. An empty piece writes nothing. A write that fails throws
    /// `storageFailed` and uses no number; after `end`, it throws `runEnded`.
    func append(_ piece: String) throws {
        try lock.withLock {
            guard let sealer else { throw NoteError.runEnded }
            guard !piece.isEmpty else { return }
            let sequence = lastSequence + 1
            do {
                let record = try sealer.seal(Data(piece.utf8), as: .segment(noteID, run: runID, sequence: sequence))
                try storage.writeRunFile(record, named: "\(NoteStoredNames.segmentPrefix)\(sequence)", run: runID,
                                         order: order, of: noteID)
            } catch {
                throw NoteError.storageFailed
            }
            lastSequence = sequence
        }
    }

    /// Ends the run: drops its key, and the run no longer counts as recording, so the vault may merge it.
    func end() {
        lock.withLock { sealer = nil }
        storage.endRun(runID)
    }
}

/// The JSON of sealed plaintexts: sorted keys, dates in seconds since 1970, as the shared store's records.
enum NoteCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }
}
