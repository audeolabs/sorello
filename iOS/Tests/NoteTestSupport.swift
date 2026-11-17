import Foundation

/// The key store of the tests: a secret in memory, a passcode switch, and the user's answer to authentication.
final class FakeNoteKeyStore: NoteKeyStore, @unchecked Sendable {
    var deviceHasPasscode = true
    var secret: Data?
    /// What the user does when asked: authenticate, or cancel.
    var userCancels = false
    /// Runs while the user is asked, before they answer.
    var whileAsking: (() -> Void)?
    private(set) var prompts: [String] = []

    func hasSecret() -> Bool { secret != nil }

    func storeSecret(_ secret: Data) throws { self.secret = secret }

    func readSecret(prompt: String) throws -> Data {
        prompts.append(prompt)
        whileAsking?()
        guard let secret else { throw NoteKeyStoreError.notFound }
        guard !userCancels else { throw NoteKeyStoreError.cancelled }
        return secret
    }

    func deleteSecret() throws { secret = nil }
}

/// A notes directory in a fresh temporary directory, with its vault and recorder, and a clock the test moves.
final class NoteFixture {
    let root: URL
    let directory: URL
    let keyStore = FakeNoteKeyStore()
    private(set) var storage: NoteStorage
    private(set) var vault: NoteVault
    private(set) var recorder: NoteRecorder
    var now = Fixture.now

    /// Joins a run's pieces with spaces, and puts a space between it and the text around its place where none is.
    static let format: NoteRunFormatter = { pieces, before, after in
        var text = pieces.joined(separator: " ")
        guard !text.isEmpty else { return "" }
        if let last = before.last, !last.isWhitespace { text = " " + text }
        if let first = after.first, !first.isWhitespace { text += " " }
        return text
    }

    init() {
        root = TestSupport.makeTemporaryDirectory()
        directory = root.appendingPathComponent("SorelloNotes", isDirectory: true)
        storage = NoteStorage(directory: directory)
        vault = NoteVault(storage: storage, keyStore: keyStore, formatRun: Self.format)
        recorder = NoteRecorder(storage: storage)
        relaunch()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// A new process on the same files and key store: nothing in memory carries over, no run records.
    func relaunch() {
        storage = NoteStorage(directory: directory)
        vault = NoteVault(storage: storage, keyStore: keyStore, formatRun: Self.format, now: { [unowned self] in now })
        recorder = NoteRecorder(storage: storage, now: { [unowned self] in now })
    }

    func unlock() {
        try! vault.unlock(prompt: "Read your notes")
    }

    /// Records `pieces` as one run into `target` and ends it.
    @discardableResult
    func record(_ pieces: [String], into target: NoteRunTarget = .newNote) -> UUID {
        let writer = try! recorder.beginRun(target)
        for piece in pieces { try! writer.append(piece) }
        writer.end()
        return writer.noteID
    }

    /// Every regular file under the notes directory, by path relative to it.
    func files() -> [String: Data] {
        var files: [String: Data] = [:]
        let base = directory.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if let data = try? Data(contentsOf: url) {
                files[String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))] = data
            }
        }
        return files
    }

    func noteDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent("note-\(id.uuidString)", isDirectory: true)
    }

    /// The directories of a note's runs, by order.
    func runDirectories(of id: UUID) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: noteDirectory(id).path)) ?? []
        return names.filter { $0.hasPrefix("run-") }
            .sorted { Int($0.split(separator: "-")[1])! < Int($1.split(separator: "-")[1])! }
            .map { noteDirectory(id).appendingPathComponent($0, isDirectory: true) }
    }

    func noteTexts() -> [String] {
        try! vault.notes().map(\.text)
    }
}

/// Whether `haystack` holds `needle`'s bytes anywhere.
func noteBytes(_ haystack: Data, contain needle: String) -> Bool {
    haystack.range(of: Data(needle.utf8)) != nil
}
