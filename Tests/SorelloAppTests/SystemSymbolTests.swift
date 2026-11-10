import Foundation
import Testing

/// ARCHITECTURE.md, section 11: every system symbol Sorello names exists on the minimum system. A symbol name the
/// system does not have draws nothing, silently, so the compiler cannot catch one that is newer than the minimum.
///
/// The system's own record of when each symbol appeared is read from its symbol bundle, and every string literal in
/// Sources that the record knows as a symbol is checked against `MINIMUM_SYSTEM` in Config/identity.conf, whatever
/// route the name takes to the screen. Symbol names are therefore written as literals, never built from parts.
@Suite("System symbols")
struct SystemSymbolTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let record = URL(
        fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")

    /// Literals the record knows only as an old name of a renamed symbol, which it gives no date for. Each is checked
    /// by hand and listed with what it is.
    private static let undatedNames: [String: String] = [
        "volume": "a spoken word in TextRules' number rules, not a symbol",
    ]

    /// When each symbol appeared, by the macOS release that first had it, and the old names of renamed symbols.
    private struct Record {
        let releases: [String: [Int]]
        let oldNames: Set<String>

        init() throws {
            let data = try Data(contentsOf: SystemSymbolTests.record)
            let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any], "the system's symbol record is not a dictionary")
            let symbols = try #require(plist["symbols"] as? [String: String], "the record has no symbols")
            let years = try #require(plist["year_to_release"] as? [String: [String: String]],
                                     "the record has no releases")
            var releases: [String: [Int]] = [:]
            for (name, year) in symbols {
                releases[name] = try #require(years[year]?["macOS"].map(SystemSymbolTests.version),
                                              "\(name)'s release \(year)")
            }
            self.releases = releases
            let aliases = SystemSymbolTests.record.deletingLastPathComponent().appending(path: "name_aliases.strings")
            oldNames = Set((NSDictionary(contentsOf: aliases) as? [String: String] ?? [:]).keys)
        }
    }

    @Test("The system's record dates symbols as the SF Symbols releases did")
    func recordIsRead() throws {
        let record = try Record()
        #expect(record.releases["mic"] == [10, 15], "SF Symbols 1")
        #expect(record.releases["character.cursor.ibeam"] == [11, 3], "SF Symbols 2.1")
        #expect(record.releases["microphone"] == [15, 0], "SF Symbols 6")
        #expect(record.releases.values.contains { [15, 0].lexicographicallyPrecedes($0) },
                "the record knows symbols newer than macOS 15, so the check below can fail")
        #expect(record.oldNames.contains("volume"), "the record's old names are read")
    }

    @Test("Every symbol Sorello names exists on the minimum system")
    func symbolsExistOnTheMinimumSystem() throws {
        let record = try Record()
        let minimum = try minimumSystem()
        var named = 0
        for (name, place) in try literals() {
            if let release = record.releases[name] {
                named += 1
                #expect(!minimum.lexicographicallyPrecedes(release),
                        "\(place) names \"\(name)\", which first appeared in macOS \(text(release))")
            } else if record.oldNames.contains(name) {
                #expect(Self.undatedNames[name] != nil,
                        "\(place) names \"\(name)\", an old name of a renamed symbol that the record gives no date for")
            }
        }
        #expect(named > 40, "the scan finds the symbols Sorello names")
    }

    /// `MINIMUM_SYSTEM` from Config/identity.conf, the minimum the app's Info.plist declares.
    private func minimumSystem() throws -> [Int] {
        let identity = try String(contentsOf: Self.repository.appending(path: "Config/identity.conf"), encoding: .utf8)
        let line = try #require(identity.split(separator: "\n").first { $0.hasPrefix("MINIMUM_SYSTEM=") })
        return Self.version(String(line.dropFirst("MINIMUM_SYSTEM=".count)))
    }

    /// Every string literal in Sources shaped like a symbol name, with the first file and line naming it.
    private func literals() throws -> [(String, String)] {
        let sources = Self.repository.appending(path: "Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var found: [String: String] = [:]
        for case let file as URL in files where file.pathExtension == "swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                for match in line.matches(of: #/"([a-z0-9]+(?:\.[a-z0-9]+)*)"/#) where found[String(match.1)] == nil {
                    let path = file.path.replacingOccurrences(of: Self.repository.path + "/", with: "")
                    found[String(match.1)] = "\(path):\(index + 1)"
                }
            }
        }
        #expect(!found.isEmpty, "Sources are where the test expects them")
        return found.sorted { $0.key < $1.key }
    }

    private static func version(_ text: String) -> [Int] {
        let parts = text.split(separator: ".").map { Int($0) ?? 0 }
        return parts.count == 1 ? parts + [0] : parts
    }

    private func text(_ version: [Int]) -> String { version.map(String.init).joined(separator: ".") }
}
