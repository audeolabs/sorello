import Foundation

/// A file that may be absent, or present but not readable (protected while the iPhone is locked, or an I/O error).
enum NoteStoredFile: Equatable {
    case absent
    case unreadable
    case data(Data)
}

/// A run's files as they lie in its note's directory, still sealed.
struct NoteStoredRun {
    var id: UUID
    var order: Int
    var start: Data?
    /// By sequence number, ascending.
    var segments: [(sequence: UInt32, record: Data)]
    var isRecording: Bool
    /// Whether every file of the run could be read. One that could not (protected while the iPhone is locked, or an
    /// I/O error) may be readable later.
    var isReadable: Bool
}

/// The notes directory (ARCHITECTURE.md, "Notes", Storage): where each file lies, its protection class, staged
/// writes, deletes, leftovers, and which runs record in this process. It reads and writes sealed records only and
/// holds no key. Thread-safe.
final class NoteStorage: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var recordingRuns: [UUID: UUID] = [:]   // run ID: note ID
    /// While set, no run begins.
    private var erasing = false

    init(directory: URL) {
        self.directory = directory
    }

    /// `Library/Application Support/SorelloNotes/` in the app's own container.
    static func appDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                    create: true)
            .appendingPathComponent(NoteStoredNames.directory, isDirectory: true)
    }

    /// Bodies and the recovery wrap: class A on devices, as `AtomicRecordFiles.completeProtection`.
    static var lockedAwayProtection: Data.WritingOptions { AtomicRecordFiles.completeProtection }

    /// The public key, run starts and segments, which a run creates while the iPhone may be locked: class B
    /// (`.completeUnlessOpen`) on devices. macOS and the simulator use class C, as the shared store does.
    static var writableWhileLockedProtection: Data.WritingOptions {
        #if os(iOS) && !targetEnvironment(simulator)
        return .completeFileProtectionUnlessOpen
        #else
        return .completeFileProtectionUntilFirstUserAuthentication
        #endif
    }

    // MARK: The vault's files

    func readPublicKey() -> NoteStoredFile { read(directory.appendingPathComponent(NoteStoredNames.publicKey)) }

    func writePublicKey(_ data: Data) throws {
        try write(data, to: directory.appendingPathComponent(NoteStoredNames.publicKey),
                  protection: Self.writableWhileLockedProtection)
    }

    func readRecoveryWrap() -> NoteStoredFile { read(directory.appendingPathComponent(NoteStoredNames.recoveryWrap)) }

    func writeRecoveryWrap(_ data: Data) throws {
        try write(data, to: directory.appendingPathComponent(NoteStoredNames.recoveryWrap),
                  protection: Self.lockedAwayProtection)
    }

    /// Whether the directory holds anything of a vault: its public key, its recovery wrap or a note.
    var holdsVault: Bool {
        names(in: directory).contains { name in
            name == NoteStoredNames.publicKey || name == NoteStoredNames.recoveryWrap || noteID(fromDirectory: name) != nil
        }
    }

    /// Erases: runs `deleteSecret`, then removes the whole directory, and no run begins in between. Refused while a
    /// run records.
    func erase(deletingSecret deleteSecret: () throws -> Void) throws {
        try locked {
            guard recordingRuns.isEmpty else { throw NoteError.noteIsRecording }
            erasing = true
        }
        defer { lock.withLock { erasing = false } }
        try deleteSecret()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw NoteError.storageFailed
        }
    }

    // MARK: Notes

    func noteIDs() -> [UUID] {
        names(in: directory).compactMap(noteID(fromDirectory:))
    }

    func readBody(of noteID: UUID) -> NoteStoredFile {
        read(noteDirectory(noteID).appendingPathComponent(NoteStoredNames.body))
    }

    func writeBody(_ record: Data, of noteID: UUID) throws {
        let directory = noteDirectory(noteID)
        try write(record, to: directory.appendingPathComponent(NoteStoredNames.body), protection: Self.lockedAwayProtection)
    }

    /// The note's runs that have a directory, by order.
    func runs(of noteID: UUID) -> [NoteStoredRun] {
        let directory = noteDirectory(noteID)
        // Runs begin under the lock, so a run listed here is never one that records but shows as ended.
        let (listed, recording) = lock.withLock { (names(in: directory), Set(recordingRuns.keys)) }
        return listed.compactMap { name -> NoteStoredRun? in
            guard let (order, id) = run(fromDirectory: name) else { return nil }
            let runDirectory = directory.appendingPathComponent(name, isDirectory: true)
            var start: Data?
            var segments: [(sequence: UInt32, record: Data)] = []
            // A directory that cannot be listed may hold anything.
            let files = try? FileManager.default.contentsOfDirectory(atPath: runDirectory.path)
            var isReadable = files != nil
            for file in files ?? [] {
                let url = runDirectory.appendingPathComponent(file)
                if file == NoteStoredNames.runStart {
                    start = try? Data(contentsOf: url)
                    isReadable = isReadable && start != nil
                } else if file.hasPrefix(NoteStoredNames.segmentPrefix),
                          let sequence = UInt32(file.dropFirst(NoteStoredNames.segmentPrefix.count)), sequence > 0 {
                    if let record = try? Data(contentsOf: url) {
                        segments.append((sequence, record))
                    } else {
                        isReadable = false
                    }
                }
            }
            segments.sort { $0.sequence < $1.sequence }
            return NoteStoredRun(id: id, order: order, start: start, segments: segments, isRecording: recording.contains(id),
                                 isReadable: isReadable)
        }
        .sorted { $0.order < $1.order }
    }

    /// Removes a run's files; never one that records.
    func removeRun(_ runID: UUID, order: Int, of noteID: UUID) {
        lock.withLock {
            guard recordingRuns[runID] == nil else { return }
            try? FileManager.default.removeItem(at: runDirectory(runID, order: order, of: noteID))
        }
    }

    /// Removes a note's directory if it holds no body and no run. Never one with a run that records.
    func removeNoteIfEmpty(_ noteID: UUID) {
        lock.withLock {
            let directory = noteDirectory(noteID)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
                  names.allSatisfy({ $0.hasPrefix(AtomicRecordFiles.stagingPrefix) }),
                  !recordingRuns.values.contains(noteID) else { return }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Deletes a note: renames its directory away in one step, then removes it. Refused while it records.
    func deleteNote(_ noteID: UUID) throws {
        try locked {
            guard !recordingRuns.values.contains(noteID) else { throw NoteError.noteIsRecording }
            let doomed = directory.appendingPathComponent(NoteStoredNames.deletedPrefix + UUID().uuidString,
                                                          isDirectory: true)
            guard rename(noteDirectory(noteID).path, doomed.path) == 0 else {
                throw errno == ENOENT ? NoteError.noSuchNote : NoteError.storageFailed
            }
            try? FileManager.default.removeItem(at: doomed)
        }
    }

    /// Removes what a delete or a staged write cut short left: deleted notes' directories and staging files, except
    /// in the directories of runs that record.
    func removeLeftovers() {
        lock.withLock {
            let recording = Set(recordingRuns.keys)
            files(in: directory).sweepStagingFiles { _ in false }
            for name in names(in: directory) where name.hasPrefix(NoteStoredNames.deletedPrefix) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name, isDirectory: true))
            }
            for noteID in noteIDs() {
                let noteDirectory = noteDirectory(noteID)
                files(in: noteDirectory).sweepStagingFiles { _ in false }
                for name in names(in: noteDirectory) {
                    guard let (_, runID) = run(fromDirectory: name), !recording.contains(runID) else { continue }
                    files(in: noteDirectory.appendingPathComponent(name, isDirectory: true)).sweepStagingFiles { _ in false }
                }
            }
        }
    }

    // MARK: Runs that record

    /// Reads the public key, makes a run's directory, in a new note's directory if `noteID` is nil, and counts the
    /// run as recording until `endRun`, all in one step that an erase cannot come between. Fails with `noVault`
    /// without a public key or during an erase, `unavailable` if it cannot be read, and `noSuchNote` if the note's
    /// directory is gone.
    func beginRun(of existingNoteID: UUID?) throws -> (noteID: UUID, runID: UUID, order: Int, publicKey: Data) {
        try locked {
            guard !erasing else { throw NoteError.noVault }
            let publicKey: Data
            switch readPublicKey() {
            case .absent: throw NoteError.noVault
            case .unreadable: throw NoteError.unavailable
            case .data(let data): publicKey = data
            }
            let noteID = existingNoteID ?? UUID()
            let noteDirectory = noteDirectory(noteID)
            if existingNoteID == nil {
                do {
                    try FileManager.default.createDirectory(at: noteDirectory, withIntermediateDirectories: true)
                } catch {
                    throw NoteError.storageFailed
                }
            } else if !FileManager.default.fileExists(atPath: noteDirectory.path) {
                throw NoteError.noSuchNote
            }
            let order = (names(in: noteDirectory).compactMap { run(fromDirectory: $0)?.order }.max() ?? 0) + 1
            let runID = UUID()
            do {
                try FileManager.default.createDirectory(at: runDirectory(runID, order: order, of: noteID),
                                                        withIntermediateDirectories: false)
            } catch {
                throw NoteError.storageFailed
            }
            recordingRuns[runID] = noteID
            return (noteID, runID, order, publicKey)
        }
    }

    func writeRunFile(_ record: Data, named name: String, run runID: UUID, order: Int, of noteID: UUID) throws {
        let url = runDirectory(runID, order: order, of: noteID).appendingPathComponent(name)
        try write(record, to: url, protection: Self.writableWhileLockedProtection)
    }

    func endRun(_ runID: UUID) {
        lock.withLock { _ = recordingRuns.removeValue(forKey: runID) }
    }

    // MARK: Names and files

    private func noteDirectory(_ noteID: UUID) -> URL {
        directory.appendingPathComponent(NoteStoredNames.notePrefix + noteID.uuidString, isDirectory: true)
    }

    private func runDirectory(_ runID: UUID, order: Int, of noteID: UUID) -> URL {
        noteDirectory(noteID).appendingPathComponent("\(NoteStoredNames.runPrefix)\(order)-\(runID.uuidString)",
                                                     isDirectory: true)
    }

    private func noteID(fromDirectory name: String) -> UUID? {
        guard name.hasPrefix(NoteStoredNames.notePrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(NoteStoredNames.notePrefix.count)))
    }

    private func run(fromDirectory name: String) -> (order: Int, id: UUID)? {
        guard name.hasPrefix(NoteStoredNames.runPrefix) else { return nil }
        let rest = name.dropFirst(NoteStoredNames.runPrefix.count)
        guard let dash = rest.firstIndex(of: "-"), let order = Int(rest[..<dash]), order > 0,
              let id = UUID(uuidString: String(rest[rest.index(after: dash)...])) else { return nil }
        return (order, id)
    }

    private func names(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    private func files(in directory: URL) -> AtomicRecordFiles {
        AtomicRecordFiles(directory: directory, stagingSuffix: NoteStoredNames.stagingSuffix, excludedFromBackup: false)
    }

    private func read(_ url: URL) -> NoteStoredFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return .data(data)
    }

    private func write(_ data: Data, to url: URL, protection: Data.WritingOptions) throws {
        do {
            try files(in: url.deletingLastPathComponent()).write(data, to: url, protection: protection)
        } catch {
            throw NoteError.storageFailed
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
