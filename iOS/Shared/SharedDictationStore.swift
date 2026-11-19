import Foundation

/// File-backed state shared by the host app and the keyboard. Each file has one writer process and
/// every write is atomic, so a reader sees either the previous or the new record. Reads never throw
/// and never log content.
struct SharedDictationStore: Sendable {
    let directory: URL

    /// Returns nil when the App Group container is unavailable (a missing entitlement or group).
    init?(configuration: SorelloConfiguration) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier) else { return nil }
        self.init(directory: Self.directory(inContainer: container))
    }

    init(directory: URL) {
        self.directory = directory
    }

    static func directory(inContainer container: URL) -> URL {
        // Kept: this directory is on people's iPhones (ARCHITECTURE.md, "Identifiers").
        container.appendingPathComponent("Library/Caches/SorelloDictation", isDirectory: true)
    }

    // MARK: Reads

    func readIntent() -> StoreRead<KeyboardIntent> { read(at: intentURL) }

    func readPresence() -> StoreRead<KeyboardPresence> { read(at: presenceURL) }

    func readStatus() -> StoreRead<HostStatus> { read(at: statusURL) }

    func readResult(requestID: UUID) -> StoreRead<DictationResult> {
        let outcome: StoreRead<DictationResult> = read(at: resultURL(for: requestID))
        // A record under another request's name is corrupt, not a result for this request.
        if let result = outcome.value, result.requestID != requestID { return .unreadable }
        return outcome
    }

    /// `added-word.json` where it lies: the keyboard's view of the file it alone writes. The host never reads it there:
    /// it takes it first (`takeAddedWord`).
    func readAddedWord() -> StoreRead<AddedWord> { read(at: addedWordURL) }

    /// The request IDs of every result file present, whether or not it is readable.
    func resultRequestIDs() -> [UUID] {
        resultFiles().map(\.requestID)
    }

    /// Like `resultRequestIDs()`, but nil when the directory exists and could not be listed, so a
    /// caller can tell a failed listing from no results. A missing directory holds no results.
    func listResultRequestIDs() -> [UUID]? {
        do {
            return Self.resultFiles(named: try FileManager.default.contentsOfDirectory(atPath: directory.path),
                                    in: directory).map(\.requestID)
        } catch {
            // Foundation reports "no such file" even when a parent cannot be searched, so only `stat`
            // failing with ENOENT counts as a missing directory. Anything else (no permission, not a
            // directory, an I/O error) is a failure, never an empty listing.
            var info = stat()
            return stat(directory.path, &info) != 0 && errno == ENOENT ? [] : nil
        }
    }

    // MARK: Writes

    func writeIntent(_ intent: KeyboardIntent) throws {
        try write(intent, to: intentURL, protection: Self.completeProtection)
    }

    func writePresence(_ presence: KeyboardPresence) throws {
        try write(presence, to: presenceURL, protection: .completeFileProtectionUntilFirstUserAuthentication)
    }

    func writeStatus(_ status: HostStatus) throws {
        // JSONEncoder throws on NaN, and a failed heartbeat would make the host look dead.
        var status = status
        status.level = status.level.isFinite ? min(max(status.level, 0), 1) : 0
        try write(status, to: statusURL, protection: .completeFileProtectionUntilFirstUserAuthentication)
    }

    func writeResult(_ result: DictationResult) throws {
        try write(result, to: resultURL(for: result.requestID), protection: Self.completeProtection)
    }

    /// The keyboard's write, over any word not yet claimed (ARCHITECTURE.md, "Files", One added word).
    func writeAddedWord(_ word: AddedWord) throws {
        try write(word, to: addedWordURL, protection: Self.completeProtection)
    }

    // MARK: Deletes

    enum ResultRemoval: Equatable, Sendable {
        /// This call removed the file, so this caller won the claim.
        case removed
        /// Another claimant or a purge removed it first.
        case alreadyAbsent
        /// The file may still be there (for example a transient I/O error); a later attempt may succeed.
        case failed
    }

    /// Removes `result-R.json` so that exactly one caller, across threads and processes, sees `.removed`.
    func removeResult(requestID: UUID) -> ResultRemoval {
        removeResultFile(at: resultURL(for: requestID))
    }

    /// Deletes results whose age is outside `[-clockSkewTolerance, resultTTL]`. A result that cannot
    /// be decoded (for example while the device is locked) is judged by its file's modification date.
    /// Also sweeps staging files abandoned for as long, so either process cleans up after a crash.
    func purgeExpiredResults(now: Date) {
        defer { purgeStagingFiles(olderThan: DictationProtocol.resultTTL, now: now) }
        for (requestID, url) in resultFiles() {
            let timestamp: Date?
            if let result = readResult(requestID: requestID).value {
                timestamp = result.createdAt
            } else {
                timestamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            }
            guard let timestamp, !DictationProtocol.isFresh(timestamp, ttl: DictationProtocol.resultTTL, now: now)
            else { continue }
            _ = removeResultFile(at: url)
        }
    }

    /// Deletes every result for which `shouldDelete` returns true. Used for run recovery and session end.
    func purgeResults(where shouldDelete: (UUID, StoreRead<DictationResult>) -> Bool) {
        for (requestID, url) in resultFiles() where shouldDelete(requestID, readResult(requestID: requestID)) {
            _ = removeResultFile(at: url)
        }
    }

    /// Deletes staging files whose modification date is outside `[-clockSkewTolerance, age]`. A writer
    /// that dies between writing and renaming leaves one behind, and a result's may hold a transcript.
    /// The host passes 0 during run recovery, before it writes anything, to remove them at any age.
    /// Other callers keep a long age so they never pull an in-flight write from under the other process.
    /// The keyboard's `.staging-kd-` files hold no content and may belong to a keyboard writing now: whatever `age`,
    /// they are kept while fresh within `resultTTL` ("Files", Staging sweeps).
    func purgeStagingFiles(olderThan age: TimeInterval, now: Date) {
        files.sweepStagingFiles { name, modified in
            let ttl = name.hasPrefix(Self.stagingPrefix + Self.keyboardDictationStagingTag)
                ? max(age, DictationProtocol.resultTTL) : age
            return DictationProtocol.isFresh(modified, ttl: ttl, now: now)
        }
    }

    // MARK: The added word (ARCHITECTURE.md, "Files", One added word)

    /// A copy of `added-word.json` the host has taken: renamed to a private staging name, so it alone holds it and
    /// what it judges is the version it took, never one the keyboard wrote over it since.
    struct TakenAddedWord: Equatable, Sendable {
        let url: URL
    }

    /// The host takes `added-word.json`: one rename to a private staging name, which only one caller can win. Nil
    /// when there is none (or the rename failed; a later take tries again).
    func takeAddedWord() -> TakenAddedWord? {
        let taken = files.makeStagingURL()
        guard rename(addedWordURL.path, taken.path) == 0 else { return nil }
        return TakenAddedWord(url: taken)
    }

    /// The taken copy's record; `.absent` once it is gone (removed, or swept as an abandoned staging file).
    func readTaken(_ taken: TakenAddedWord) -> StoreRead<AddedWord> { read(at: taken.url) }

    /// The taken copy's modification date: the keyboard's write, which a rename keeps.
    func modificationDate(of taken: TakenAddedWord) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: taken.url.path))?[.modificationDate] as? Date
    }

    func removeTaken(_ taken: TakenAddedWord) {
        _ = unlink(taken.url.path)
    }

    enum AddedWordPurge: Equatable, Sendable {
        /// There is no `added-word.json`, or the host took it before it could be removed.
        case absent
        /// Still fresh: judged again at `deadline`.
        case kept(deadline: Date)
        /// Expired, and removed.
        case removed
        /// Expired, but the removal failed; try again later.
        case failed
    }

    /// The keyboard's purge: judges `added-word.json` where it lies, by `issuedAt` or, unreadable, by its modification
    /// date, and removes it by name only once it is not fresh within `addedWordTTL`. Only the keyboard writes the
    /// file, on its main thread, as it purges, so this never meets its own write; a name found gone was taken by the
    /// host.
    @discardableResult
    func purgeExpiredAddedWord(now: Date) -> AddedWordPurge {
        let stamp: Date?
        switch readAddedWord() {
        case .absent:
            return .absent
        case .value(let word):
            stamp = word.issuedAt
        case .unreadable, .incompatible:
            stamp = (try? FileManager.default.attributesOfItem(atPath: addedWordURL.path))?[.modificationDate] as? Date
        }
        if let stamp, DictationProtocol.isFresh(stamp, ttl: DictationProtocol.addedWordTTL, now: now) {
            return .kept(deadline: stamp + DictationProtocol.addedWordTTL)
        }
        if unlink(addedWordURL.path) == 0 { return .removed }
        return errno == ENOENT ? .absent : .failed
    }

    // MARK: In-keyboard dictation (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Record)

    /// Tags the staging files of `keyboard-dictation.json`, which the launch sweep leaves.
    static let keyboardDictationStagingTag = "kd-"

    #if SORELLO_KEYBOARD_DICTATION
    func readKeyboardDictation() -> StoreRead<KeyboardDictationRecord> { read(at: keyboardDictationURL) }

    /// The tap's write, which starts a record with a new attempt id over the last dictation's. Class C: it holds no
    /// content.
    func writeKeyboardDictation(_ record: KeyboardDictationRecord) throws {
        try write(record.sanitized, to: keyboardDictationURL, protection: .completeFileProtectionUntilFirstUserAuthentication,
                  stagingTag: Self.keyboardDictationStagingTag)
    }

    enum RecordReplacement: Equatable, Sendable {
        case written
        /// The record holds another attempt's id, or is `abandoned`, or is gone: it was left as it was.
        case skipped
        case failed
    }

    /// Every write after the tap's: reads the record and replaces it with `record` only if `mayReplace` allows, for
    /// `record`'s attempt. Not locked against another keyboard process (only one keyboard is visible at a time).
    @discardableResult
    func replaceKeyboardDictation(_ record: KeyboardDictationRecord) -> RecordReplacement {
        guard let attemptID = record.attemptID,
              KeyboardDictationRecord.mayReplace(readKeyboardDictation(), forAttempt: attemptID) else { return .skipped }
        return (try? writeKeyboardDictation(record)) == nil ? .failed : .written
    }

    enum AbandonedRecord: Equatable, Sendable {
        /// No unfinished record of another process.
        case none
        /// There was one: rewritten as `abandoned`, or (`rewritten` false) the rewrite failed.
        case found(rewritten: Bool)
    }

    /// The route's check at a tap: a record left unfinished by another keyboard process is rewritten with the outcome
    /// `abandoned`, keeping its steps, only while it is still unfinished.
    func abandonUnfinishedKeyboardDictation(notWrittenBy processID: UUID) -> AbandonedRecord {
        guard var record = readKeyboardDictation().value, record.isUnfinished(byAnotherProcessThan: processID) else {
            return .none
        }
        record.markAbandoned()
        return .found(rewritten: (try? writeKeyboardDictation(record)) != nil)
    }
    #endif

    // MARK: Files

    var intentURL: URL { directory.appendingPathComponent("intent.json", isDirectory: false) }
    var presenceURL: URL { directory.appendingPathComponent("presence.json", isDirectory: false) }
    var statusURL: URL { directory.appendingPathComponent("status.json", isDirectory: false) }
    var addedWordURL: URL { directory.appendingPathComponent("added-word.json", isDirectory: false) }
    var keyboardDictationURL: URL { directory.appendingPathComponent("keyboard-dictation.json", isDirectory: false) }

    func resultURL(for requestID: UUID) -> URL {
        directory.appendingPathComponent("result-\(requestID.uuidString).json", isDirectory: false)
    }

    private func resultFiles() -> [(requestID: UUID, url: URL)] {
        Self.resultFiles(named: (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [], in: directory)
    }

    private static func resultFiles(named names: [String], in directory: URL) -> [(requestID: UUID, url: URL)] {
        names.sorted().compactMap { name in
            guard name.hasPrefix("result-"), name.hasSuffix(".json"),
                  let id = UUID(uuidString: String(name.dropFirst("result-".count).dropLast(".json".count)))
            else { return nil }
            return (id, directory.appendingPathComponent(name, isDirectory: false))
        }
    }

    /// Class A (`.complete`) on devices; class C on macOS and the simulator (`AtomicRecordFiles`).
    private static var completeProtection: Data.WritingOptions { AtomicRecordFiles.completeProtection }

    private struct SchemaProbe: Decodable {
        var schema: Int
    }

    private func read<Record: Decodable>(at url: URL) -> StoreRead<Record> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .absent
        } catch {
            return .unreadable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // Check the schema first: a future version may change the other fields entirely.
        guard let probe = try? decoder.decode(SchemaProbe.self, from: data) else { return .unreadable }
        guard probe.schema == DictationProtocol.schema else { return .incompatible }
        guard let record = try? decoder.decode(Record.self, from: data) else { return .unreadable }
        return .value(record)
    }

    static let stagingPrefix = AtomicRecordFiles.stagingPrefix
    static let stagingSuffix = ".tmp"

    private var files: AtomicRecordFiles { AtomicRecordFiles(directory: directory, stagingSuffix: Self.stagingSuffix) }

    /// Every result removal, claim or purge, goes through here. On APFS, concurrent unlinks of one
    /// name can all succeed, but only one rename of it can, so the file is first moved to a private
    /// staging name and deleted from there. A crash in between leaves a staging file for the sweeps.
    private func removeResultFile(at url: URL) -> ResultRemoval {
        let claimed = files.makeStagingURL()
        guard rename(url.path, claimed.path) == 0 else { return errno == ENOENT ? .alreadyAbsent : .failed }
        _ = unlink(claimed.path)
        return .removed
    }

    /// Writes a uniquely named staging file next to the destination, then renames it over the
    /// destination: a reader sees the old or the new record, never part of one (`AtomicRecordFiles`).
    private func write<Record: Encodable>(_ record: Record, to url: URL, protection: Data.WritingOptions,
                                          stagingTag: String = "") throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(record)
        try files.write(data, to: url, protection: protection, stagingTag: stagingTag)
    }
}
