import DictationCore
import Foundation
import Observation

/// One dictation in the Run Log. It holds what was heard and inserted, and how it ended; never the app it went to.
public struct HistoryEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    /// When the dictation was recorded.
    public var date: Date
    /// The recognizer's transcript; empty when transcription failed.
    public var heard: String
    /// What was inserted; empty when transcription failed.
    public var text: String
    public var outcome: DictationOutcome
    /// The recording's length in seconds.
    public var duration: TimeInterval

    public init(id: UUID, date: Date, heard: String, text: String, outcome: DictationOutcome,
                duration: TimeInterval) {
        self.id = id
        self.date = date
        self.heard = heard
        self.text = text
        self.outcome = outcome
        self.duration = duration
    }
}

/// The Run Log (ARCHITECTURE.md, section 7): the last 20 dictations and their audio, in `index.json` and one WAV file
/// per entry inside the directory it is given. The directory and its files are readable by the user only.
///
/// - One writer, off the main actor, does all saving, deleting and clearing, one operation at a time.
/// - An entry appears in the index, and in `entries`, only after its audio is on disk. Audio with no entry, and
///   temporary files, are removed when the log is first read.
/// - When a 21st entry arrives, the oldest entry and its audio are deleted.
/// - `clear` removes the index, every audio file and every temporary file, and cancels every save that began
///   before it.
/// - An index that cannot be read (damaged, or from a newer version of the app) is deleted, not kept.
/// - Recording is skipped while the user has "Keep Run Log" off. Failures are recorded in `Diagnostics` and never
///   thrown: the Run Log never interrupts dictation.
@MainActor
@Observable
public final class HistoryStore: HistoryRecording {
    /// The most entries the log keeps.
    public static let capacity = 20

    /// The entries, newest first, as they are on disk.
    public private(set) var entries: [HistoryEntry] = []

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    @ObservationIgnored private let writer: HistoryWriter
    /// How many times the log has been cleared. A save carries the count from when it began, so the writer can tell
    /// which saves a clear cancels.
    @ObservationIgnored private var clearCount = 0
    /// One save being written and one waiting behind it: enough to keep the writer busy, and a bound on the audio
    /// it holds.
    private static let admittedSaves = 2
    @ObservationIgnored private var savesWithWriter = 0
    @ObservationIgnored private var waitingSaves: [CheckedContinuation<Void, Never>] = []
    /// The newest writer snapshot shown, so a slower operation's older snapshot never replaces a newer one.
    @ObservationIgnored private var shownRevision = -1

    /// A log in `directory`. `isEnabled` is asked at the start of each save: the "Keep Run Log" setting. Nothing is
    /// read or written until the first operation; call `load()` at launch to show the entries and tidy the
    /// directory.
    public init(directory: URL, isEnabled: @escaping @MainActor () -> Bool) {
        self.directory = directory.standardizedFileURL
        self.isEnabled = isEnabled
        writer = HistoryWriter(directory: self.directory, capacity: Self.capacity)
    }

    /// Reads the index, deletes it if it cannot be read, and removes audio that no entry names.
    public func load() async {
        show(await writer.load(clearCount: clearCount))
    }

    /// Saves `draft` and its audio as the newest entry. Does nothing while "Keep Run Log" is off.
    ///
    /// A recording can be 15 minutes long, so saves never pile up at the writer: the samples are converted to the
    /// 16-bit file first, off the main actor, and at most one save is being written while one more waits for it.
    /// Further calls wait here, holding only their converted audio, until it is their turn.
    public func record(_ draft: HistoryDraft) async {
        guard isEnabled() else { return }
        let began = clearCount
        let entry = HistoryEntry(id: UUID(), date: draft.date, heard: draft.heard, text: draft.text,
                                 outcome: draft.outcome,
                                 duration: Double(draft.samples.count) / AudioFormat.sampleRate)
        let audio = await Self.encode(draft.samples)
        await admitSave()
        defer { releaseSave() }
        guard began == clearCount else { return }
        show(await writer.save(entry, audio: audio, clearCount: began))
    }

    /// Deletes the entry with `id` and its audio.
    public func delete(id: HistoryEntry.ID) async {
        show(await writer.delete(id: id, clearCount: clearCount))
    }

    /// Replaces an entry's transcript, text and outcome after a retry, keeping its audio, date and place. An entry
    /// that has since been deleted stays deleted.
    public func replace(id: HistoryEntry.ID, heard: String, text: String, outcome: DictationOutcome) async {
        show(await writer.replace(id: id, heard: heard, text: text, outcome: outcome, clearCount: clearCount))
    }

    /// Deletes every entry, every audio file and every temporary file, and cancels every save that began before this
    /// call. `entries` is empty as soon as this is called.
    public func clear() async {
        clearCount += 1
        entries = []
        show(await writer.clear(clearCount: clearCount))
    }

    /// The entry's audio file, for playback. Nil when there is no such entry.
    public func audioURL(for id: HistoryEntry.ID) -> URL? {
        guard entries.contains(where: { $0.id == id }) else { return nil }
        return HistoryWriter.audioURL(for: id, in: directory)
    }

    /// The entry's recording, 16 kHz mono, for a retry. Nil when the entry or its audio is gone or unreadable.
    public func samples(for id: HistoryEntry.ID) async -> [Float]? {
        await writer.samples(for: id, clearCount: clearCount)
    }

    /// Converts a recording to the bytes of its file, on the shared pool rather than the main actor.
    @concurrent private nonisolated static func encode(_ samples: [Float]) async -> Data {
        WAVAudio.encode(samples)
    }

    /// Waits until fewer than `admittedSaves` saves are with the writer, then takes a place. Places are handed on in
    /// the order the saves asked for them.
    private func admitSave() async {
        if savesWithWriter < Self.admittedSaves {
            savesWithWriter += 1
            return
        }
        await withCheckedContinuation { waitingSaves.append($0) }
    }

    /// Gives the place to the next waiting save, or frees it.
    private func releaseSave() {
        if waitingSaves.isEmpty {
            savesWithWriter -= 1
        } else {
            waitingSaves.removeFirst().resume()
        }
    }

    private func show(_ snapshot: HistoryWriter.Snapshot?) {
        guard let snapshot, snapshot.clearCount == clearCount, snapshot.revision > shownRevision else { return }
        shownRevision = snapshot.revision
        entries = snapshot.entries
    }
}

// MARK: - Writer

/// The one writer of a Run Log directory. It runs on its own serial queue because its work is blocking file I/O,
/// which should not occupy the shared concurrency pool.
actor HistoryWriter {
    /// The index after an operation. `revision` grows with every change; `clearCount` names the clear it follows.
    struct Snapshot: Sendable {
        var entries: [HistoryEntry]
        var revision: Int
        var clearCount: Int
    }

    private struct Index: Codable {
        static let currentVersion = 1
        var version: Int
        var entries: [HistoryEntry]
    }

    private static let indexName = "index.json"

    private let directory: URL
    private let capacity: Int
    private let queue = DispatchSerialQueue(label: "sorello.history-writer")
    /// Nil until the index has been read.
    private var entries: [HistoryEntry]?
    private var revision = 0
    private var clearCount = 0

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(directory: URL, capacity: Int) {
        self.directory = directory
        self.capacity = capacity
    }

    static func audioURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString.lowercased()).wav", isDirectory: false)
    }

    private var indexURL: URL { directory.appendingPathComponent(Self.indexName, isDirectory: false) }

    // MARK: Operations

    func load(clearCount: Int) -> Snapshot {
        catchUp(to: clearCount)
        return snapshot(loaded())
    }

    /// Writes the audio, then the index that names it, then deletes what the cap evicted. Nil when the save was
    /// cancelled by a clear or failed; a failed save leaves nothing behind.
    func save(_ entry: HistoryEntry, audio: Data, clearCount: Int) -> Snapshot? {
        guard clearCount >= self.clearCount else { return nil }
        catchUp(to: clearCount)
        let current = loaded()
        let audioURL = Self.audioURL(for: entry.id, in: directory)
        do {
            try StoredFile.ensurePrivateDirectory(directory)
            try StoredFile.writeAtomically(audio, to: audioURL)
        } catch {
            Diagnostics.record("history.audioWriteFailed")
            return nil
        }
        let updated = [entry] + current
        guard writeIndex(Array(updated.prefix(capacity))) else {
            try? FileManager.default.removeItem(at: audioURL)
            return nil
        }
        for evicted in updated.dropFirst(capacity) {
            try? FileManager.default.removeItem(at: Self.audioURL(for: evicted.id, in: directory))
        }
        return snapshot(Array(updated.prefix(capacity)))
    }

    func delete(id: UUID, clearCount: Int) -> Snapshot? {
        catchUp(to: clearCount)
        let current = loaded()
        guard current.contains(where: { $0.id == id }) else { return snapshot(current) }
        guard writeIndex(current.filter { $0.id != id }) else { return nil }
        try? FileManager.default.removeItem(at: Self.audioURL(for: id, in: directory))
        return snapshot(loaded())
    }

    func replace(id: UUID, heard: String, text: String, outcome: DictationOutcome, clearCount: Int) -> Snapshot? {
        catchUp(to: clearCount)
        var updated = loaded()
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return snapshot(updated) }
        updated[index].heard = heard
        updated[index].text = text
        updated[index].outcome = outcome
        guard writeIndex(updated) else { return nil }
        return snapshot(updated)
    }

    func clear(clearCount: Int) -> Snapshot {
        catchUp(to: clearCount)
        return snapshot(loaded())
    }

    func samples(for id: UUID, clearCount: Int) -> [Float]? {
        catchUp(to: clearCount)
        guard loaded().contains(where: { $0.id == id }),
              let data = try? Data(contentsOf: Self.audioURL(for: id, in: directory)) else { return nil }
        return try? WAVAudio.decode(data)
    }

    // MARK: State

    /// A clear the main actor has asked for and this writer has not yet done is done first, so a save that began
    /// after a clear is never wiped by it.
    private func catchUp(to requested: Int) {
        guard requested > clearCount else { return }
        clearCount = requested
        wipe()
    }

    /// The index, read on first use. An unreadable index is deleted; audio and temporary files that no entry names
    /// are removed.
    private func loaded() -> [HistoryEntry] {
        if let entries { return entries }
        var found: [HistoryEntry]
        switch StoredFile.readVersioned(Index.self, from: indexURL, version: Index.currentVersion) {
        case .value(let index):
            found = index.entries
        case .missing:
            found = []
        case .unreadable:
            Diagnostics.record("history.indexUnreadable")
            try? FileManager.default.removeItem(at: indexURL)
            found = []
        }
        let manager = FileManager.default
        // An entry whose audio has gone cannot be played or retried; keep the index true to the disk.
        let kept = Array(found.filter { Self.hasAudio($0.id, in: directory) }
            .prefix(capacity))
        if kept.count != found.count {
            _ = writeIndex(kept)
        }
        found = kept
        let named = Set(found.map { Self.audioURL(for: $0.id, in: directory).lastPathComponent })
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where (name.hasSuffix(".wav") && !named.contains(name)) || StoredFile.isTemporary(name) {
            if (try? manager.removeItem(at: directory.appendingPathComponent(name))) != nil { removed += 1 }
        }
        if removed > 0 { Diagnostics.record("history.orphansRemoved", ["count": Double(removed)]) }
        entries = found
        return found
    }

    private static func hasAudio(_ id: UUID, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: audioURL(for: id, in: directory).path)
    }

    /// Writes the index and adopts it. An empty log has no index file at all.
    private func writeIndex(_ updated: [HistoryEntry]) -> Bool {
        do {
            if updated.isEmpty {
                if FileManager.default.fileExists(atPath: indexURL.path) {
                    try FileManager.default.removeItem(at: indexURL)
                }
            } else {
                try StoredFile.ensurePrivateDirectory(directory)
                try StoredFile.writeVersioned(Index(version: Index.currentVersion, entries: updated), to: indexURL)
            }
        } catch {
            Diagnostics.record("history.indexWriteFailed")
            return false
        }
        entries = updated
        revision += 1
        return true
    }

    /// Removes everything in the directory: the index, every audio file and every temporary file.
    private func wipe() {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        var failed = 0
        for name in names where (try? manager.removeItem(at: directory.appendingPathComponent(name))) == nil {
            failed += 1
        }
        if failed > 0 { Diagnostics.record("history.clearIncomplete", ["count": Double(failed)]) }
        entries = []
        revision += 1
    }

    private func snapshot(_ entries: [HistoryEntry]) -> Snapshot {
        Snapshot(entries: entries, revision: revision, clearCount: clearCount)
    }
}
