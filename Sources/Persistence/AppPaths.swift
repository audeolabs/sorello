import Foundation

/// Where Sorello keeps its files (ARCHITECTURE.md, section 7): `Application Support/<bundle id>/`, in a directory
/// only the user can read. The bundle identifier is passed in, so development and release builds never share data
/// and tests can point everything at a temporary directory.
public struct AppPaths: Sendable, Equatable {
    /// `Application Support/<bundle id>`, or the directory given to `init(root:)`.
    public let root: URL

    /// Every path under `root`, for tests and for a caller that already knows where the data lives.
    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Resolves `Application Support/<bundleIdentifier>` for the current user. The identifier must be a single
    /// path component, so a malformed one cannot point the app's data somewhere else.
    public init(bundleIdentifier: String) throws(AppPathsError) {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw .noApplicationSupport }
        try self.init(bundleIdentifier: bundleIdentifier, applicationSupport: support)
    }

    /// `<applicationSupport>/<bundleIdentifier>`, with the identifier checked as `init(bundleIdentifier:)` checks it.
    /// For a process that finds an app's data from outside the app, as the `sorello` command does, with the user's
    /// Application Support directory passed in so tests can point it elsewhere.
    public init(bundleIdentifier: String, applicationSupport: URL) throws(AppPathsError) {
        guard !bundleIdentifier.isEmpty, bundleIdentifier != ".", bundleIdentifier != "..",
              !bundleIdentifier.contains("/"), !bundleIdentifier.contains("\0") else {
            throw .invalidBundleIdentifier
        }
        self.init(root: applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true))
    }

    /// The custom dictionary, owned by `DictionaryKit`.
    public var dictionaryFile: URL { root.appendingPathComponent("dictionary.json", isDirectory: false) }

    /// The voice macros (`MacroStore`).
    public var macrosFile: URL { root.appendingPathComponent("macros.json", isDirectory: false) }

    /// The Run Log: `index.json` and one WAV file per entry (`HistoryStore`).
    public var historyDirectory: URL { root.appendingPathComponent("history", isDirectory: true) }

    /// Where the speech engine keeps its copy of the model, so Core ML's compiled cache survives app updates.
    public var modelsDirectory: URL { root.appendingPathComponent("Models", isDirectory: true) }

    /// Creates `root` if it is missing and makes it readable by the user only. Called once at launch, before any
    /// store writes; each store also creates the directory it writes into.
    public func prepare() throws {
        try StoredFile.ensurePrivateDirectory(root)
    }
}

public enum AppPathsError: Error, Sendable, Equatable {
    /// Empty, `.` or `..`, or containing a slash: not usable as one directory name.
    case invalidBundleIdentifier
    /// The system did not name an Application Support directory for this user.
    case noApplicationSupport
}
