import DictationCore
import DictionaryKit
import Foundation
import SpeechEngine

// sorello-transcribe: transcribes audio files with the real model through the engine's streaming path, for
// verification (ARCHITECTURE.md, section 11). Each transcript goes to standard output; where the encoder runs, what a
// download fetched, and preparation and transcription times, go to standard error. It reads only the files it is
// given and writes only the model store it is pointed at. With --download it fetches this Mac's build of the model
// into that store as the app does, from the pin's address or, to stage a failure, from --source.

let usage = """
    usage: sorello-transcribe --model <bundle-dir> [--store <dir>] [options] <file>...
           sorello-transcribe --download --pin <file> --store <dir> [--source <address>] [options] <file>...
      --model     the model bundle (the directory holding bundle.json)
      --store     where to keep the stable copy of the model; without it the bundle is loaded in place
      --download  download the build the pin lists for this Mac into --store, as the app does, then transcribe
      --pin       the pin, Models/model.lock.json
      --source    fetch the build from this address instead of the pin's: HTTPS, or plain HTTP to 127.0.0.1
    options:
      --word      a dictionary word, with an optional strength (default 1); repeat for more
      --sounds-like  a spelling the recognizer writes for the --word before it; repeat for more (at most 4)
      --realtime  hand the audio over at the speed it would be recorded, and time only the wait after the end
      --cpu       run the encoder on Core ML's CPU kernels, as on a Mac without a Neural Engine
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}

var model: URL?
var store: URL?
var downloads = false
var pinFile: URL?
var source: URL?
var realtime = false
var forcesCPU = false
var words: [DictionaryEntry] = []
var files: [URL] = []
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--model":
        guard let value = arguments.popFirst() else { fail(usage) }
        model = URL(fileURLWithPath: value, isDirectory: true)
    case "--store":
        guard let value = arguments.popFirst() else { fail(usage) }
        store = URL(fileURLWithPath: value, isDirectory: true)
    case "--download":
        downloads = true
    case "--pin":
        guard let value = arguments.popFirst() else { fail(usage) }
        pinFile = URL(fileURLWithPath: value)
    case "--source":
        guard let value = arguments.popFirst(), let url = URL(string: value) else { fail(usage) }
        source = url
    case "--word":
        guard let value = arguments.popFirst() else { fail(usage) }
        var text = value, strength = DictionaryValidation.defaultStrength
        if let equals = value.lastIndex(of: "="), let parsed = Float(value[value.index(after: equals)...]) {
            text = String(value[..<equals])
            strength = parsed
        }
        switch DictionaryValidation.validate(text: text, strength: strength, encoder: nil) {
        case .success(let entry): words.append(entry)
        case .failure(let error): fail("sorello-transcribe: a --word cannot be used: \(error.message)")
        }
    case "--sounds-like":
        guard let value = arguments.popFirst(), !words.isEmpty else { fail(usage) }
        words[words.count - 1].soundsLike.append(value)
    case "--realtime":
        realtime = true
    case "--cpu":
        forcesCPU = true
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        guard !argument.hasPrefix("-") else { fail(usage) }
        files.append(URL(fileURLWithPath: argument))
    }
}
guard !files.isEmpty, downloads ? (model == nil && pinFile != nil && store != nil) : (model != nil && pinFile == nil),
      source == nil || downloads else { fail(usage) }

func seconds(_ duration: Duration) -> String {
    let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    return String(format: "%.3f s", value)
}

/// The version the download names itself with: the app's, from `Config/identity.conf` beside the pin's directory.
func version(besidePin pin: URL) -> String {
    let identity = pin.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Config/identity.conf")
    let lines = (try? String(contentsOf: identity, encoding: .utf8))?.split(separator: "\n") ?? []
    return lines.first { $0.hasPrefix("VERSION=") }.map { String($0.dropFirst("VERSION=".count)) } ?? "0"
}

/// Downloads this Mac's build of the model into `store`, says what was fetched, and returns the model to load.
func download(pinFile: URL, store: URL, source: URL?) async -> PinnedModel {
    var pin: ModelPin
    do {
        pin = try ModelPin(contentsOf: pinFile)
        if let source { pin = try pin.replacingSource(source) }
    } catch {
        fail("sorello-transcribe: the pin cannot be used (\(error))")
    }
    let model = PinnedModel(pin: pin, storeDirectory: store)
    guard let build = model.build else { fail("sorello-transcribe: the pin lists no build for this Mac") }
    FileHandle.standardError.write(Data("download: build \(build.directory), \(build.bytes) bytes\n".utf8))
    let report = await ModelDownload(model: model, version: version(besidePin: pinFile)).download()
    var lines: [String] = []
    if report.wasAlreadyThere {
        lines.append("download: the model was already in the store; nothing fetched")
    } else {
        let ending = switch report.state {
        case .installed: "installed"
        case .failed(let reason): "failed, \(reason)"
        case .absent: "stopped"
        case .unavailable: "no build for this Mac"
        case .downloading: "still downloading"
        }
        lines.append(String(format: "download: %@, %lld bytes fetched in %.3f s", ending, report.fetched, report.seconds))
    }
    for offset in report.continuedFrom { lines.append("download: continued a file from byte \(offset)") }
    if report.startedAgain > 0 {
        lines.append("download: \(report.startedAgain) file(s) sent again from the start; the server ignored the range")
    }
    FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    guard report.state == .installed else { exit(1) }
    return model
}

// Spellings follow the dictionary's rules (DESIGN §3.7): checked for their word, and one key means one thing.
for index in words.indices {
    switch SoundsLike.validate(words[index].soundsLike, word: words[index].text, encoder: nil) {
    case .success(let spellings): words[index].soundsLike = spellings
    case .failure(let error): fail("sorello-transcribe: a --sounds-like cannot be used: \(error.message)")
    }
}
guard words.allSatisfy({ $0.soundsLike.isEmpty }) || CustomDictionary(entries: words, ignore: []) != nil else {
    fail("sorello-transcribe: two --word or --sounds-like values have the same key")
}
let snapshot = DictionarySnapshot(revision: 1, entries: words)
let compute = forcesCPU ? SpeechCompute.cpu : .forThisMac()
let engine: SpeechEngine
if downloads, let pinFile, let store {
    engine = SpeechEngine(model: await download(pinFile: pinFile, store: store, source: source), compute: compute,
                          dictionary: { _ in snapshot })
} else {
    engine = SpeechEngine(modelDirectory: model, storeDirectory: store, compute: compute, dictionary: { _ in snapshot })
}
let reason = forcesCPU ? "forced by --cpu" : "this Mac's hardware"
FileHandle.standardError.write(Data("encoder: \(engine.compute) (\(reason))\n".utf8))
let clock = ContinuousClock()
let prepared = clock.now
await engine.prepare()
/// The engine's readiness now, which is the first value every subscription hears.
func currentReadiness(of engine: SpeechEngine) async -> EngineReadiness? {
    for await readiness in engine.readiness() { return readiness }
    return nil
}
let state = await currentReadiness(of: engine)
FileHandle.standardError.write(Data("preparation: \(seconds(clock.now - prepared)) (\(String(describing: state ?? .preparing)))\n".utf8))
guard state == .ready else { exit(1) }

var failed = false
for file in files {
    let samples: [Float]
    do {
        samples = try AudioFileReader.samples(contentsOf: file)
    } catch {
        FileHandle.standardError.write(Data("\(file.lastPathComponent): could not be read\n".utf8))
        failed = true
        continue
    }
    let stream = engine.openStream(SpeechStreamOptions())
    let started = clock.now
    // 100 ms pieces, as the microphone delivers them.
    let piece = Int(AudioFormat.sampleRate) / 10
    for start in stride(from: 0, to: samples.count, by: piece) {
        stream.append(Array(samples[start..<min(start + piece, samples.count)]))
        if realtime { try? await Task.sleep(for: .milliseconds(100)) }
    }
    let ended = clock.now
    do {
        let result = try await stream.finish()
        let audio = Double(samples.count) / AudioFormat.sampleRate
        let timing = "\(file.lastPathComponent): \(String(format: "%.1f", audio)) s of audio, "
            + "transcribed in \(seconds(clock.now - started)), \(seconds(clock.now - ended)) after the end"
        FileHandle.standardError.write(Data((timing + "\n").utf8))
        print(result.text)
    } catch {
        FileHandle.standardError.write(Data("\(file.lastPathComponent): transcription failed (\(error))\n".utf8))
        failed = true
    }
}
exit(failed ? 1 : 0)
