import Foundation
import Testing
@testable import SpeechEngine

/// The pin and the choice of build (ARCHITECTURE.md, section 5, "Getting the model"). Every pin here is invented: the
/// addresses are under example.com and the digests are made up.
struct ModelPinTests {
    static let digest = String(repeating: "a1", count: 32)
    static let other = String(repeating: "b2", count: 32)

    /// A pin with `builds`, each a JSON object written out, under `source`.
    static func pin(source: String = "https://models.example.com/resolve/0123abcd", builds: [String]) -> Data {
        Data("""
            {"model": "kea-x", "export_sha256": "\(other)", "manifest": "bundle.json", "source": "\(source)",
             "builds": [\(builds.joined(separator: ","))]}
            """.utf8)
    }

    static func build(_ directory: String, requires: String, digest: String = digest, bytes: String = "1000") -> String {
        """
        {"directory": "\(directory)", "manifest_sha256": "\(digest)", "bytes": \(bytes), "requires": \(requires)}
        """
    }

    static func mac(_ version: String) throws -> MacDescription {
        MacDescription(system: try #require(SystemVersion(version)))
    }

    @Test func readsThePinsShape() throws {
        let pin = try ModelPin(data: Self.pin(builds: [Self.build("macos26", requires: #"{"macos": "26.0"}"#,
                                                                  bytes: "138084519")]))
        #expect(pin.model == "kea-x")
        #expect(pin.source.absoluteString == "https://models.example.com/resolve/0123abcd")
        #expect(pin.builds.count == 1)
        let build = try #require(pin.builds.first)
        #expect(build.directory == "macos26")
        #expect(build.manifestSHA256 == Self.digest)
        #expect(build.bytes == 138_084_519)
        #expect(pin.address(of: "bundle.json", in: build).absoluteString
                == "https://models.example.com/resolve/0123abcd/macos26/bundle.json")
        #expect(pin.address(of: "Encoder.mlmodelc/weights/weight.bin", in: build).absoluteString
                == "https://models.example.com/resolve/0123abcd/macos26/Encoder.mlmodelc/weights/weight.bin")
    }

    /// The repository's own pin reads, and gives this Mac (macOS 26 or later, as the package requires) its build.
    @Test func theRepositorysPinGivesThisMacItsBuild() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Models/model.lock.json")
        let pin = try ModelPin(contentsOf: file)
        let build = try #require(pin.build(for: .current()))
        #expect(build.directory == "macos26")
        #expect(build.bytes == 138_084_560)
        #expect(pin.build(for: try Self.mac("15.7")) == nil)
    }

    @Test func theFirstFittingBuildWins() throws {
        let pin = try ModelPin(data: Self.pin(builds: [
            Self.build("newest", requires: #"{"macos": "27.0"}"#, digest: Self.other),
            Self.build("first", requires: #"{"macos": "26.0"}"#),
            Self.build("second", requires: #"{"macos": "15.0"}"#),
        ]))
        #expect(pin.build(for: try Self.mac("27.2"))?.directory == "newest")
        #expect(pin.build(for: try Self.mac("26.4"))?.directory == "first")
        #expect(pin.build(for: try Self.mac("15.7"))?.directory == "second")
        #expect(pin.build(for: try Self.mac("14.6")) == nil, "No fitting build is an answer, not an error")
    }

    @Test(arguments: [("26.0", "26.0", true), ("26.0", "26.1", true), ("26.0", "27.2", true), ("26.0", "15.7", false),
                      ("26.0", "26", true), ("26", "26.0.1", true), ("26.1", "26.0.9", false), ("9.0", "10.0", true),
                      ("10.0", "9.9", false), ("26.10", "26.9", false), ("26.9", "26.10", true)])
    func versionsCompareAsNumbers(required: String, system: String, fits: Bool) throws {
        let pin = try ModelPin(data: Self.pin(builds: [Self.build("only", requires: "{\"macos\": \"\(required)\"}")]))
        #expect((pin.build(for: try Self.mac(system)) != nil) == fits, "\(required) on \(system)")
    }

    @Test func versionsReadOnlyAsNumbers() {
        #expect(SystemVersion("26.0") == SystemVersion("26"))
        #expect(SystemVersion("26.0.0") == SystemVersion("26"))
        for text in ["", "26.", ".26", "26..1", "26.x", "v26", "26.0.0.1", "-1", "26 ", "２６"] {
            #expect(SystemVersion(text) == nil, "\(text) is not a version")
        }
    }

    /// A requirement this version of Sorello does not know is passed over, whatever else the build says, so a later
    /// pin can list builds for other Macs without an older app taking one.
    @Test func aBuildWithAnUnknownRequirementIsPassedOver() throws {
        let pin = try ModelPin(data: Self.pin(builds: [
            Self.build("ane-only", requires: #"{"macos": "26.0", "neural_engine": true}"#),
            #"{"directory": 7, "bytes": "many", "requires": {"intel": false}}"#,
            Self.build("plain", requires: #"{"macos": "26.0"}"#, digest: Self.other),
        ]))
        #expect(pin.build(for: try Self.mac("27.2"))?.directory == "plain")
        #expect(pin.builds.map(\.directory) == ["plain"])
    }

    /// A known requirement that cannot be judged passes the build over too: it never fits by mistake.
    @Test func aBuildWhoseRequirementCannotBeJudgedIsPassedOver() throws {
        let pin = try ModelPin(data: Self.pin(builds: [
            Self.build("number", requires: #"{"macos": 26}"#),
            Self.build("words", requires: #"{"macos": "twenty-six"}"#),
            Self.build("plain", requires: #"{"macos": "26.0"}"#, digest: Self.other),
        ]))
        #expect(pin.builds.map(\.directory) == ["plain"])
    }

    @Test func aBuildThatRequiresNothingFitsEveryMac() throws {
        let pin = try ModelPin(data: Self.pin(builds: [Self.build("any", requires: "{}")]))
        #expect(pin.build(for: try Self.mac("12.0"))?.directory == "any")
    }

    @Test func noBuildsIsNotAnError() throws {
        let pin = try ModelPin(data: Self.pin(builds: []))
        #expect(pin.build(for: try Self.mac("27.2")) == nil)
    }

    @Test(arguments: [
        "not json",
        "[]",
        #"{"model": "kea-x", "source": "https://models.example.com/r"}"#,
        #"{"source": "https://models.example.com/r", "builds": []}"#,
    ])
    func aPinThatCannotBeReadIsRefused(text: String) {
        #expect(throws: ModelPinError.unreadable) { try ModelPin(data: Data(text.utf8)) }
    }

    /// A build this version can judge must read in full: its directory is a plain relative path, its digest is a
    /// SHA-256 in lowercase hexadecimal and its size a positive whole number.
    @Test(arguments: [
        ModelPinTests.build("", requires: "{}"), ModelPinTests.build("/macos26", requires: "{}"),
        ModelPinTests.build("../macos26", requires: "{}"), ModelPinTests.build("macos26/..", requires: "{}"),
        ModelPinTests.build("a//b", requires: "{}"), ModelPinTests.build("./macos26", requires: "{}"),
        ModelPinTests.build("mac\\\\os", requires: "{}"),
        ModelPinTests.build("macos26", requires: "{}", digest: "abc"),
        ModelPinTests.build("macos26", requires: "{}", digest: String(repeating: "A1", count: 32)),
        ModelPinTests.build("macos26", requires: "{}", bytes: "0"),
        ModelPinTests.build("macos26", requires: "{}", bytes: "-5"),
        ModelPinTests.build("macos26", requires: "{}", bytes: "1.5"),
        ModelPinTests.build("macos26", requires: "{}", bytes: "\"10\""),
        #"{"directory": "macos26", "manifest_sha256": "\#(ModelPinTests.digest)", "bytes": 10}"#,
        #"{"directory": "macos26", "manifest_sha256": "\#(ModelPinTests.digest)", "bytes": 10, "requires": []}"#,
    ])
    func aKnownBuildThatCannotBeReadRefusesThePin(build: String) {
        #expect(throws: ModelPinError.unreadable) { try ModelPin(data: Self.pin(builds: [build])) }
    }

    @Test func onlyTheManifestTheEngineReadsIsAccepted() {
        let text = #"{"model": "kea-x", "manifest": "model.json", "source": "https://models.example.com/r", "builds": []}"#
        #expect(throws: ModelPinError.unreadable) { try ModelPin(data: Data(text.utf8)) }
    }

    @Test(arguments: ["http://models.example.com/resolve/0123", "ftp://models.example.com/x", "file:///tmp/models",
                      "https://", "models.example.com/x", "https://user:secret@models.example.com/x",
                      "https://models.example.com/x?token=1", "https://models.example.com/x#part"])
    func aSourceThatIsNotPlainHTTPSIsRefused(source: String) {
        #expect(throws: ModelPinError.notHTTPS) {
            try ModelPin(data: Self.pin(source: source, builds: [Self.build("macos26", requires: "{}")]))
        }
    }

    /// Only the verification tool replaces the source, and only with HTTPS or plain HTTP to this Mac itself.
    @Test func aVerificationSourceIsHTTPSOrThisMac() throws {
        let pin = try ModelPin(data: Self.pin(builds: [Self.build("macos26", requires: "{}")]))
        for source in ["http://127.0.0.1:8123/repo", "http://[::1]:8123/repo", "https://mirror.example.com/repo"] {
            let replaced = try pin.replacingSource(try #require(URL(string: source)))
            #expect(replaced.source.absoluteString == source)
            #expect(replaced.builds == pin.builds)
        }
        for source in ["http://192.168.1.4:8123/repo", "http://models.example.com/repo", "http://127.0.0.2/repo",
                       "http://localhost:8123/repo", "file:///tmp/repo"] {
            #expect(throws: ModelPinError.notHTTPS, "\(source)") {
                try pin.replacingSource(try #require(URL(string: source)))
            }
        }
    }
}
