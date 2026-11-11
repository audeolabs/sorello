import Foundation
import Testing
@testable import SpeechEngine

/// Which build a Mac uses, and where its model is (ARCHITECTURE.md, section 5, "Getting the model"). Invented files.
struct PinnedModelTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("PinnedModelTests-\(UUID().uuidString)")
    var store: URL { base.appendingPathComponent("Models", isDirectory: true) }

    func mac(_ version: String) throws -> MacDescription {
        MacDescription(system: try #require(SystemVersion(version)))
    }

    /// Writes `build` as an app's own copy of the model, or as a complete download into the store.
    func write(_ build: ModelDownloadTests.Build, to directory: URL, manifest: Data? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (manifest ?? build.manifest).write(to: directory.appendingPathComponent("bundle.json"))
        for (path, data) in build.files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    @Test func aMacUsesTheFirstBuildItMeetsAndNothingIsHereYet() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let build = ModelDownloadTests.Build()
        let model = PinnedModel(pin: build.pin, storeDirectory: store, mac: try mac("26.1"))
        #expect(model.build?.manifestSHA256 == build.identity)
        #expect(model.carriedDirectory == nil)
        #expect(!model.isOnThisMac)
        #expect(model.vocabulary() == nil)
        #expect(PinnedModel(pin: build.pin, storeDirectory: store, mac: try mac("15.7")).build == nil)
    }

    /// An app built with the model carries a build the pin lists; a copy of anything else is ignored.
    @Test func aCarriedCopyCountsOnlyWhenThePinListsItForThisMac() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let build = ModelDownloadTests.Build()
        let carried = base.appendingPathComponent("App.app/Contents/Resources/Model", isDirectory: true)
        try write(build, to: carried)
        let model = PinnedModel(pin: build.pin, storeDirectory: store, carriedDirectory: carried, mac: try mac("27.2"))
        #expect(model.carriedDirectory == carried)
        #expect(model.isOnThisMac)
        #expect(model.vocabulary() != nil, "The dictionary can use the carried model's vocabulary")
        #expect(PinnedModel(pin: build.pin, storeDirectory: store, carriedDirectory: carried, mac: try mac("15.7"))
            .carriedDirectory == nil, "A build this Mac does not meet is not used")

        let other = base.appendingPathComponent("Other.app/Contents/Resources/Model", isDirectory: true)
        try write(build, to: other, manifest: Data("{\"files\":{}}".utf8))
        let unlisted = PinnedModel(pin: build.pin, storeDirectory: store, carriedDirectory: other, mac: try mac("27.2"))
        #expect(unlisted.carriedDirectory == nil)
        #expect(!unlisted.isOnThisMac)
    }

    /// The dictionary reads the vocabulary only from a stored copy whose manifest is pinned and whose file matches it.
    @Test func theVocabularyComesFromAVerifiedStoredCopy() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let build = ModelDownloadTests.Build()
        let models = ModelStore(root: store)
        guard case .download(let directory) = models.prepareDownload(build.identity) else {
            Issue.record("No download directory")
            return
        }
        try write(build, to: directory)
        let installed = try #require(models.installDownload(build.identity))
        let model = PinnedModel(pin: build.pin, storeDirectory: store, mac: try mac("27.2"))
        #expect(model.isOnThisMac)
        #expect(model.vocabulary() != nil)
        try Data("{\"0\":\"▁edited\"}".utf8).write(to: installed.appendingPathComponent("vocabulary.json"))
        #expect(model.vocabulary() == nil, "A vocabulary that does not match the manifest is not used")
    }
}
