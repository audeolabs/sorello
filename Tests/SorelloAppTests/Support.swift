import Foundation
import Testing

/// A fresh directory for one test, removed afterwards. Every store under test writes only inside it.
struct TemporaryDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorello-app-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A `UserDefaults` suite of its own for one test, removed afterwards, so tests never touch real settings.
struct TemporaryDefaults: ~Copyable {
    let suiteName = "sorello-app-tests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// Waits on the main actor until `condition` holds, at most `seconds`. Records an issue and returns false when it
/// never does, so a broken path fails its test instead of hanging the run.
@MainActor
@discardableResult
func eventually(within seconds: Double = 5, sourceLocation: SourceLocation = #_sourceLocation,
                _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out after \(seconds) s", sourceLocation: sourceLocation)
            return false
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// A stand-in model directory with only what the app reads without Core ML: a 1024-piece vocabulary that spells
/// every ASCII letter, and a manifest naming the model. Enough for the dictionary to be edited.
func makeModelDirectory(in directory: URL) throws -> URL {
    let model = directory.appendingPathComponent("Model", isDirectory: true)
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    let letters = (Unicode.Scalar("a").value...Unicode.Scalar("z").value).compactMap(Unicode.Scalar.init)
        .flatMap { [String($0), String($0).uppercased()] }
    var pieces = ["<unk>", "\u{2581}", "'", "-"] + letters
    while pieces.count < 1024 { pieces.append("\u{2581}filler\(pieces.count)") }
    let vocabulary = Dictionary(uniqueKeysWithValues: pieces.enumerated().map { (String($0.offset), $0.element) })
    try JSONSerialization.data(withJSONObject: vocabulary).write(to: model.appendingPathComponent("vocabulary.json"))
    try JSONSerialization.data(withJSONObject: ["base_model": "kea-test"])
        .write(to: model.appendingPathComponent("bundle.json"))
    return model
}
