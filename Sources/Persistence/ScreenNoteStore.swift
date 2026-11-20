import Foundation

/// Where screen notes are kept (ARCHITECTURE.md, section 14, "Where notes are kept"): one folder per note under one
/// directory, readable by the user only, named by the note's start time. A note is finished once its folder holds
/// `note.json`; the newest `kept` finished notes are kept.
public struct ScreenNoteStore: Sendable {
    public static let kept = 20
    /// What marks a finished note.
    public static let manifestName = "note.json"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    /// Makes the folder for a note started at `date`, named `yyyy-MM-dd-HHmmss` on `timeZone`'s clock, with `-2`,
    /// `-3`… after it when that name is taken.
    public func makeFolder(startedAt date: Date, timeZone: TimeZone = .current) throws -> URL {
        try StoredFile.ensurePrivateDirectory(directory)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let base = formatter.string(from: date)
        let manager = FileManager.default
        var attempt = 1
        while true {
            let name = attempt == 1 ? base : "\(base)-\(attempt)"
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
                return folder
            } catch CocoaError.fileWriteFileExists {
                attempt += 1
            }
        }
    }

    /// Finished notes, newest first: by when each folder was made, which a clock change or daylight saving does not
    /// reorder as it can the names, then by name.
    public func notes() -> [URL] {
        let made = Dictionary(folders().filter(Self.isFinished).map { ($0, Self.created($0)) }, uniquingKeysWith: { a, _ in a })
        return made.keys.sorted { a, b in
            made[a]! != made[b]! ? made[a]! > made[b]! : a.lastPathComponent > b.lastPathComponent
        }
    }

    private static func created(_ folder: URL) -> Date {
        (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    /// The newest finished note.
    public func latest() -> URL? { notes().first }

    /// Deletes every finished note but the newest `kept`.
    public func prune() {
        for folder in notes().dropFirst(Self.kept) { delete(folder) }
    }

    /// Deletes every folder that is not a finished note, left by a note that never finished.
    public func removeUnfinished() {
        for folder in folders() where !Self.isFinished(folder) { delete(folder) }
    }

    /// Deletes one note's folder, if it is one of this store's.
    public func delete(_ folder: URL) {
        guard folder.standardizedFileURL.deletingLastPathComponent().path == directory.path else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private func folders() -> [URL] {
        let found = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return found.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.standardizedFileURL)
    }

    private static func isFinished(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(manifestName).path)
    }
}
