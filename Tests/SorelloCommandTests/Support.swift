import AVFoundation
import CryptoKit
import DictionaryKit
import FileTranscription
import Foundation
import SorelloCommand
import SpeechEngine
import Synchronization
import Testing
import TextRules

/// A temporary directory holding app bundles, links to their commands, and an Application Support directory, removed
/// when the test ends. Every name and word in it is invented.
final class Fixture {
    let root: URL
    var support: URL { root.appendingPathComponent("Support", isDirectory: true) }
    /// A preferences suite for the test app, removed with the fixture.
    let suite = "SorelloCommandTests-\(UUID().uuidString)"

    init() throws {
        // Resolved, so the paths the command sees after following links are the paths the test expects.
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root = temporary.appendingPathComponent("SorelloCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    /// A manifest whose digest a pin can list, so an app can carry it.
    static let manifest = Data(#"{"files":{},"base_model":"invented"}"#.utf8)
    static var manifestDigest: String { SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined() }

    /// A pin with one build, for macOS `macOS` or later.
    static func pin(macOS: String = "26.0") -> Data {
        Data("""
            {"model":"invented-model","manifest":"bundle.json","source":"https://example.invalid/model",
             "builds":[{"directory":"macos","manifest_sha256":"\(manifestDigest)","bytes":64,
                        "requires":{"macos":"\(macOS)"}}]}
            """.utf8)
    }

    /// Makes `<root>/Applications/<name>.app` with an `Info.plist`, a pin and a command at `Contents/Helpers/sorello`,
    /// and returns the command's path. `info` replaces the `Info.plist`'s keys; nil values are left out.
    @discardableResult
    func app(name: String = "Sorello Test", identifier: String? = "com.example.sorello-test",
             version: String = "0.0.1", build: String = "269", pin: Data = Fixture.pin(),
             carries: Data? = nil) throws -> URL {
        let bundle = root.appendingPathComponent("Applications/\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleName": name, "CFBundleDisplayName": name,
                                   "CFBundleShortVersionString": version, "CFBundleVersion": build]
        if let identifier { info["CFBundleIdentifier"] = identifier }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try pin.write(to: resources.appendingPathComponent("model.lock.json"))
        if let carries {
            let model = resources.appendingPathComponent("Model", isDirectory: true)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try carries.write(to: model.appendingPathComponent("bundle.json"))
        }
        let helper = helpers.appendingPathComponent("sorello")
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        return helper
    }

    /// A chain of symbolic links ending at `target`: `<root>/bin/<name>` → `<root>/links/1` → … → `target`.
    func link(to target: URL, named name: String = "sorello", through hops: Int = 2) throws -> URL {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let links = root.appendingPathComponent("links", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        var next = target
        for hop in (0..<hops).reversed() {
            let link = links.appendingPathComponent("\(name)-\(hop)")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: next)
            next = link
        }
        let first = bin.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: next)
        return first
    }

    /// The app's data directory, `Support/<identifier>`.
    func data(_ identifier: String = "com.example.sorello-test") -> URL {
        support.appendingPathComponent(identifier, isDirectory: true)
    }

    /// Writes `contents` at `name` in the app's data directory.
    func write(_ contents: Data, _ name: String, identifier: String = "com.example.sorello-test") throws {
        try FileManager.default.createDirectory(at: data(identifier), withIntermediateDirectories: true)
        try contents.write(to: data(identifier).appendingPathComponent(name))
    }

    /// One second of an invented tone, 16 kHz mono, at `name` in the fixture.
    func tone(_ name: String = "tone.wav") throws -> URL {
        let url = root.appendingPathComponent(name)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                                interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channel = try #require(buffer.floatChannelData)[0]
        for index in 0..<16_000 { channel[index] = Float(0.1 * sin(2 * Double.pi * 440 * Double(index) / 16_000)) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    /// Every file and directory under `url`, with each file's bytes and modification date, to tell whether anything
    /// changed.
    static func snapshot(_ url: URL) -> [String: String] {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return [:] }
        var found: [String: String] = [:]
        for case let item as URL in walker {
            let attributes = (try? FileManager.default.attributesOfItem(atPath: item.path)) ?? [:]
            let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let bytes = (try? Data(contentsOf: item)).map { SHA256.hash(data: $0).description } ?? "directory"
            found[item.path] = "\(bytes) \(date) \(attributes[.posixPermissions] ?? "")"
        }
        return found
    }
}

/// What the command wrote, from any thread.
final class Output: Sendable {
    private let streams = Mutex<(out: String, error: String)>(("", ""))
    var standardOutput: String { streams.withLock { $0.out } }
    var standardError: String { streams.withLock { $0.error } }
    /// Each line of standard error.
    var errorLines: [String] { standardError.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) }
    func out(_ text: String) { streams.withLock { $0.out += text } }
    func error(_ text: String) { streams.withLock { $0.error += text } }
}

/// Opens once; everyone waiting, and everyone who waits later, goes on.
final class Gate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = state.withLock { state -> Bool in
                if !state.open { state.waiters.append(continuation) }
                return state.open
            }
            if open { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// A sleep the test ends: it records what was asked for and returns when the test opens its gate.
final class ManualSleep: Sendable {
    private let asked = Mutex<[Duration]>([])
    let gate = Gate()
    var requests: [Duration] { asked.withLock { $0 } }

    var sleep: @Sendable (Duration) async -> Void {
        { [self] duration in
            asked.withLock { $0.append(duration) }
            await gate.wait()
        }
    }
}

/// Everything the fake transcriber was given.
final class Calls: Sendable {
    struct Call: Sendable {
        var file: URL
        var rules: TextRuleOptions?
    }

    private let state = Mutex<(models: [CommandModel], calls: [Call])>(([], []))
    var models: [CommandModel] { state.withLock { $0.models } }
    var calls: [Call] { state.withLock { $0.calls } }
    func made(_ model: CommandModel) { state.withLock { $0.models.append(model) } }
    func called(_ call: Call) { state.withLock { $0.calls.append(call) } }
}

/// Stands in for the engine: reports `progress`, waits for `gate` if there is one, then gives `text` or throws.
struct FakeTranscriber: FileTranscribing {
    var text = "Invented words."
    var failure: FileTranscriptionFailure?
    var progress: [FileTranscriptionProgress] = []
    var gate: Gate?
    var after: [FileTranscriptionProgress] = []
    let calls: Calls

    func transcribe(_ file: URL, rules: TextRuleOptions?,
                    progress report: @escaping @Sendable (FileTranscriptionProgress) -> Void)
        async throws(FileTranscriptionFailure) -> String {
        calls.called(Calls.Call(file: file, rules: rules))
        for value in progress { report(value) }
        await gate?.wait()
        for value in after { report(value) }
        if let failure { throw failure }
        return text
    }
}

/// Waits until `condition` holds, for at most ten seconds.
@MainActor
func eventually(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
}
