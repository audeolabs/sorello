import Foundation

/// Why a pin was refused.
public enum ModelPinError: Error, Sendable, Equatable {
    /// The file is missing, is not JSON, or a field Sorello relies on is absent or malformed.
    case unreadable
    /// The address the files are under is not plain HTTPS.
    case notHTTPS
}

/// A macOS version as the pin writes it, "26" or "26.0" or "26.0.1", compared as numbers, so 9.0 comes before 10.0
/// and 26.0 equals 26.
public struct SystemVersion: Sendable, Comparable, Hashable, CustomStringConvertible {
    /// Major, minor and patch; a part not written is 0.
    public let parts: [Int]

    /// The version `text` writes, or nil unless it is one to three whole numbers in ASCII digits, separated by dots.
    public init?(_ text: String) {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 6, piece.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(piece) else { return nil }
            parts.append(number)
        }
        self.parts = parts + Array(repeating: 0, count: 3 - parts.count)
    }

    /// The version of the system this process runs on.
    public init(_ version: OperatingSystemVersion) {
        parts = [version.majorVersion, version.minorVersion, version.patchVersion]
    }

    public static func < (lhs: SystemVersion, rhs: SystemVersion) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// What a build's requirements are judged against. Today a build can require only a lowest macOS version, so that is
/// all this holds; a fact about the hardware joins it when a requirement in the pin needs one.
public struct MacDescription: Sendable, Equatable {
    /// The system's version.
    public var system: SystemVersion

    /// A Mac running `system`.
    public init(system: SystemVersion) {
        self.system = system
    }

    /// The Mac this process runs on.
    public static func current() -> MacDescription {
        MacDescription(system: SystemVersion(ProcessInfo.processInfo.operatingSystemVersion))
    }
}

/// The pin, `Models/model.lock.json` (ARCHITECTURE.md, section 5, "Getting the model"): which model Sorello uses,
/// where its builds are, and what each needs of the Mac. The app ships it as `Contents/Resources/model.lock.json`,
/// and it is all Sorello knows about where the model is and what it must be. Every byte downloaded is checked against
/// it before anything is loaded.
public struct ModelPin: Sendable, Equatable {
    /// One complete model under `source`, for the Macs that meet its requirements.
    public struct Build: Sendable, Equatable {
        /// The build's directory under `source`, a relative path.
        public let directory: String
        /// The SHA-256 of the build's `bundle.json`, which fixes every byte of the build and names it in the store.
        public let manifestSHA256: String
        /// The whole build's size, `bundle.json` included. A download never writes more.
        public let bytes: Int64
        /// The lowest macOS the build runs on; nil when it names none.
        public let minimumSystem: SystemVersion?

        /// Whether `mac` meets every requirement of this build.
        public func fits(_ mac: MacDescription) -> Bool {
            minimumSystem.map { mac.system >= $0 } ?? true
        }
    }

    /// The manifest every build has at its top, which the engine and the store read by this name.
    public static let manifestName = "bundle.json"

    /// The model's name, as Sorello shows it.
    public let model: String
    /// The address the builds' directories are under, at one fixed revision of the model's repository.
    public let source: URL
    /// The builds this version of Sorello can judge, in the pin's order. A build that requires something this version
    /// does not know is left out, so it is never taken by mistake.
    public let builds: [Build]

    /// Reads a pin. A build whose requirements this version cannot judge is passed over however the rest of it reads;
    /// any other build must read in full, or the whole pin is refused.
    public init(data: Data) throws(ModelPinError) {
        guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any],
              let model = root["model"] as? String, !model.isEmpty,
              let sourceText = root["source"] as? String, let entries = root["builds"] as? [Any] else {
            throw .unreadable
        }
        if let manifest = root["manifest"], manifest as? String != Self.manifestName { throw .unreadable }
        guard let source = URL(string: sourceText) else { throw .unreadable }
        try Self.requireHTTPS(source, allowingThisMac: false)
        var builds: [Build] = []
        for entry in entries {
            guard let fields = entry as? [String: Any], let requires = fields["requires"] as? [String: Any] else {
                throw .unreadable
            }
            guard let minimum = Self.judgeable(requires) else { continue }
            builds.append(try Self.build(fields, minimumSystem: minimum))
        }
        self.init(model: model, source: source, builds: builds)
    }

    /// Reads the pin in the file at `url`.
    public init(contentsOf url: URL) throws(ModelPinError) {
        guard let data = try? Data(contentsOf: url) else { throw .unreadable }
        try self.init(data: data)
    }

    private init(model: String, source: URL, builds: [Build]) {
        self.model = model
        self.source = source
        self.builds = builds
    }

    /// The first build whose requirements `mac` meets; nil when none does, which is an answer, not an error.
    public func build(for mac: MacDescription) -> Build? {
        builds.first { $0.fits(mac) }
    }

    /// Where the file at `path` in `build` is downloaded from: `source`, the build's directory, then the path.
    public func address(of path: String, in build: Build) -> URL {
        source.appending(path: build.directory + "/" + path, directoryHint: .notDirectory)
    }

    /// The same pin with its builds under `source`. Only the verification tool uses this, to stage a failure against
    /// a server on the same Mac: the address must be plain HTTPS, or plain HTTP to this Mac itself.
    public func replacingSource(_ source: URL) throws(ModelPinError) -> ModelPin {
        try Self.requireHTTPS(source, allowingThisMac: true)
        return ModelPin(model: model, source: source, builds: builds)
    }

    // MARK: - Reading

    /// The requirement keys this version knows how to judge.
    private static let knownRequirements: Set<String> = ["macos"]

    /// The lowest system `requires` names, `.some(nil)` when it names none, or nil when the build must be passed
    /// over: it requires something unknown, or a known requirement cannot be judged.
    private static func judgeable(_ requires: [String: Any]) -> SystemVersion?? {
        guard Set(requires.keys).isSubset(of: knownRequirements) else { return nil }
        guard let value = requires["macos"] else { return .some(nil) }
        guard let text = value as? String, let version = SystemVersion(text) else { return nil }
        return .some(version)
    }

    private static func build(_ fields: [String: Any], minimumSystem: SystemVersion?) throws(ModelPinError) -> Build {
        guard let directory = fields["directory"] as? String, isRelativePath(directory),
              let digest = fields["manifest_sha256"] as? String, isDigest(digest),
              let bytes = wholeNumber(fields["bytes"]), bytes > 0 else {
            throw .unreadable
        }
        return Build(directory: directory, manifestSHA256: digest, bytes: bytes, minimumSystem: minimumSystem)
    }

    /// A path that stays where it is put: not empty, not absolute, no empty, `.` or `..` part, no backslash or NUL.
    static func isRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// A SHA-256 written as 64 lowercase hexadecimal digits.
    static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// A JSON number that is a whole number Int64 can hold; a string or a fraction is not one.
    private static func wholeNumber(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        return number.int64Value
    }

    /// Plain HTTPS: a host, no user or password, no query or fragment. With `allowingThisMac`, plain HTTP to this Mac
    /// itself passes too.
    private static func requireHTTPS(_ url: URL, allowingThisMac: Bool) throws(ModelPinError) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw .notHTTPS
        }
        switch components.scheme?.lowercased() {
        case "https": return
        // By address, not by name: a name such as localhost can be made to point elsewhere.
        case "http" where allowingThisMac && ["127.0.0.1", "::1", "[::1]"].contains(host):
            return
        default: throw .notHTTPS
        }
    }
}
