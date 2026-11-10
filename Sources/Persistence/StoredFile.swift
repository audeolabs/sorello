import Foundation

/// The file rules every store follows (ARCHITECTURE.md, section 7): directories and files readable by the user only,
/// whole-file atomic writes, and a `version` in every file so an unreadable one is recognised as such.
enum StoredFile {
    /// What reading a versioned file found.
    enum ReadResult<Value> {
        /// No file: a first launch, or the data was cleared.
        case missing
        case value(Value)
        /// The file exists but is damaged, truncated, not JSON, or from a newer version of the app.
        case unreadable
    }

    private struct Header: Decodable {
        var version: Int
    }

    /// Creates `directory` (and any missing parents) with owner-only access if it is missing. An existing directory
    /// is left as it is: it may not be the app's own.
    static func ensureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// Creates `directory` if needed and sets it to owner-only access, for a directory that belongs to the app.
    static func ensurePrivateDirectory(_ directory: URL) throws {
        try ensureDirectory(directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Replaces `url` with `data` in one step: the bytes go to an owner-only temporary file in the same directory,
    /// reach the disk, and are then renamed over the old file. A reader sees the old file or the new one, never a
    /// mixture, and a crash leaves at most a temporary file, which the stores remove.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    /// Whether `name` is a temporary file `writeAtomically` left behind.
    static func isTemporary(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(".tmp")
    }

    /// Reads a JSON file whose top level carries `"version": <version>`.
    static func readVersioned<Value: Decodable>(_ type: Value.Type, from url: URL, version: Int) -> ReadResult<Value> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data), header.version == version,
              let value = try? decoder.decode(Value.self, from: data) else { return .unreadable }
        return .value(value)
    }

    /// Encodes `value` and writes it atomically.
    static func writeVersioned<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeAtomically(encoder.encode(value), to: url)
    }

    /// Renames an unreadable file to `<name>.unreadable-<n>` beside it, so nothing the user made is destroyed and
    /// the store can start again with an empty file. Returns false if it could not be moved.
    @discardableResult
    static func moveAside(_ url: URL, now: Date = Date()) -> Bool {
        let manager = FileManager.default
        let stamp = Int(now.timeIntervalSince1970)
        for attempt in 0..<100 {
            let suffix = attempt == 0 ? "\(stamp)" : "\(stamp)-\(attempt)"
            let destination = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).unreadable-\(suffix)")
            guard !manager.fileExists(atPath: destination.path) else { continue }
            return (try? manager.moveItem(at: url, to: destination)) != nil
        }
        return false
    }
}
