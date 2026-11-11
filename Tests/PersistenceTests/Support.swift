import Foundation
import Testing

/// A fresh directory for one test, removed afterwards. Every store under test writes only inside it.
struct TemporaryDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorello-persistence-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Every file and directory below `url`, as paths relative to it, sorted.
    func contents() -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: url.path) else { return [] }
        return enumerator.compactMap { $0 as? String }.sorted()
    }
}

/// A `UserDefaults` suite of its own for one test, removed afterwards, so tests never touch real settings.
struct TemporaryDefaults: ~Copyable {
    let suiteName = "sorello-persistence-tests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// The POSIX permission bits of the item at `url`.
func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
}
