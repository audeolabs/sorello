import Foundation

/// The staged writes the App Group stores share (ARCHITECTURE.md, "Shared store and protocol", Staged writes):
/// the record files of one directory, each replaced whole. A write goes to a uniquely named staging file beside
/// its destination, written with the destination's protection class, then renamed over it, so a reader sees the
/// old or the new file, never part of one. A failed write removes its staging file and leaves the destination as
/// it was. Foundation's `.atomic` is avoided because its temporary file, abandoned by a crash, escapes every sweep.
///
/// Each store passes its own staging suffix, protection classes and sweep rule. Nothing here logs.
struct AtomicRecordFiles: Sendable {
    static let stagingPrefix = ".staging-"

    let directory: URL
    /// Ends every staging name, and a staging file is swept only if its name ends with it. Empty for none.
    let stagingSuffix: String
    /// Whether a directory this creates is marked excluded from backup. The App Group stores' files are
    /// transient and are; the notes, which a backup must keep, are not (ARCHITECTURE.md, "Notes", Storage).
    var excludedFromBackup = true

    /// Class A (`.complete`) on devices. macOS, where the host tests run, refuses class A to
    /// unentitled processes, and the simulator does not enforce data protection, so both use class C.
    static var completeProtection: Data.WritingOptions {
        #if os(iOS) && !targetEnvironment(simulator)
        return .completeFileProtection
        #else
        return .completeFileProtectionUntilFirstUserAuthentication
        #endif
    }

    /// A new staging name in `directory`: `.staging-`, then `tag`, a UUID and `stagingSuffix`.
    func makeStagingURL(tag: String = "") -> URL {
        directory.appendingPathComponent("\(Self.stagingPrefix)\(tag)\(UUID().uuidString)\(stagingSuffix)", isDirectory: false)
    }

    /// Replaces the file at `url`, in `directory`, with `data`: creates the directory if needed, writes a new
    /// staging file with `protection` (its name tagged with `stagingTag`) and renames it over `url`. On failure the
    /// staging file is removed and the error rethrown.
    func write(_ data: Data, to url: URL, protection: Data.WritingOptions, stagingTag: String = "") throws {
        try createDirectoryIfNeeded()
        let staging = makeStagingURL(tag: stagingTag)
        do {
            try data.write(to: staging, options: [.withoutOverwriting, protection])
            guard rename(staging.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Removes the staging files in `directory` that `isInFlight` does not keep, judged by their modification
    /// date. One whose date cannot be read is removed. Other files are never touched.
    func sweepStagingFiles(keeping isInFlight: (_ modified: Date) -> Bool) {
        sweepStagingFiles { _, modified in modified.map(isInFlight) ?? false }
    }

    /// As `sweepStagingFiles(keeping:)`, judged by each staging file's name as well as its modification date, which is
    /// nil when it cannot be read.
    func sweepStagingFiles(keeping isInFlight: (_ name: String, _ modified: Date?) -> Bool) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(Self.stagingPrefix) && name.hasSuffix(stagingSuffix) {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if isInFlight(name, modified) { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Creates `directory` unless it exists, excluded from backup if `excludedFromBackup`.
    private func createDirectoryIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard excludedFromBackup else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)   // best effort, per the contract
    }
}
