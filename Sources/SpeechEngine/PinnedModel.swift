import DictionaryKit
import Foundation

/// The model this Mac uses and where it is kept (ARCHITECTURE.md, section 5, "Getting the model"): the pin, the build
/// it lists for this Mac, the store, and the app's own copy when it carries one. The engine and the download are both
/// made from this, so they always agree on which build they mean.
public struct PinnedModel: Sendable {
    /// The pin, as the app ships it.
    public let pin: ModelPin
    /// The build this Mac uses: the one the app carries, when the pin lists it and this Mac meets it, and otherwise
    /// the first build this Mac meets. Nil when no build fits this Mac.
    public let build: ModelPin.Build?
    /// `Application Support/<bundle id>/Models`.
    public let storeDirectory: URL
    /// The app's own copy of `build`, when it was built with `SORELLO_MODEL_DIR`. A copy of any other build is
    /// ignored.
    public let carriedDirectory: URL?

    /// The model `pin` gives `mac`, kept in `storeDirectory`. `carriedDirectory` is where an app built with the model
    /// keeps it, if it has one.
    public init(pin: ModelPin, storeDirectory: URL, carriedDirectory: URL? = nil, mac: MacDescription = .current()) {
        self.pin = pin
        self.storeDirectory = storeDirectory
        let carried = carriedDirectory.flatMap { directory -> (URL, ModelPin.Build)? in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(ModelPin.manifestName)) else {
                return nil
            }
            let identity = SpeechCore.sha256(data)
            return pin.builds.first { $0.manifestSHA256 == identity && $0.fits(mac) }.map { (directory, $0) }
        }
        self.carriedDirectory = carried?.0
        build = carried?.1 ?? pin.build(for: mac)
    }

    /// Whether the model looks to be on this Mac: complete in the store, or carried by the app. A quick look, for what
    /// setup and the windows show at launch; the engine makes sure when it loads.
    public var isOnThisMac: Bool {
        guard let build else { return false }
        return carriedDirectory != nil || ModelStore(root: storeDirectory).appearsComplete(build.manifestSHA256)
    }

    /// The model's vocabulary, for the dictionary, from the store's copy or else the app's, once its manifest is the
    /// pinned one and the file matches the manifest. Nil while the model is not on this Mac.
    public func vocabulary() -> BPEEncoder? {
        guard let build else { return nil }
        let store = ModelStore(root: storeDirectory)
        let stored = store.appearsComplete(build.manifestSHA256)
            ? storeDirectory.appendingPathComponent(build.manifestSHA256, isDirectory: true) : nil
        for directory in [stored, carriedDirectory].compactMap({ $0 }) {
            guard let manifest = try? Data(contentsOf: directory.appendingPathComponent(ModelPin.manifestName)),
                  SpeechCore.sha256(manifest) == build.manifestSHA256,
                  let files = (try? JSONSerialization.jsonObject(with: manifest) as? [String: Any])?["files"]
                      as? [String: String],
                  let digest = files["vocabulary.json"],
                  let data = try? Data(contentsOf: directory.appendingPathComponent("vocabulary.json")),
                  SpeechCore.sha256(data) == digest,
                  let pieces = try? BPEEncoder.vocabularyPieces(from: data) else { continue }
            return BPEEncoder(pieces: pieces)
        }
        return nil
    }
}
