import DictationCore
import DictionaryKit
import Foundation
import SpeechEngine

// sorello-transcribe: transcribes audio files with the real model through the engine's streaming path, for
// verification (ARCHITECTURE.md, section 11). Each transcript goes to standard output; preparation and transcription
// times go to standard error. It reads only the files it is given and writes only the model store it is pointed at.

let usage = """
    usage: sorello-transcribe --model <bundle-dir> [--store <dir>] [--word <text>[=<strength>]]... [--realtime] \
    <file>...
      --model     the model bundle (the directory holding bundle.json)
      --store     where to keep the stable copy of the model; without it the bundle is loaded in place
      --word      a dictionary word, with an optional strength (default 1); repeat for more
      --realtime  hand the audio over at the speed it would be recorded, and time only the wait after the end
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}

var model: URL?
var store: URL?
var realtime = false
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
    case "--word":
        guard let value = arguments.popFirst() else { fail(usage) }
        var text = value, strength = DictionaryValidation.defaultStrength
        if let equals = value.lastIndex(of: "="), let parsed = Float(value[value.index(after: equals)...]) {
            text = String(value[..<equals])
            strength = parsed
        }
        switch DictionaryValidation.validate(text: text, strength: strength, encoder: nil) {
        case .success(let entry): words.append(entry)
        case .failure(let error): fail("sorello-transcribe: --word \(text): \(error.message)")
        }
    case "--realtime":
        realtime = true
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        guard !argument.hasPrefix("-") else { fail(usage) }
        files.append(URL(fileURLWithPath: argument))
    }
}
guard let model, !files.isEmpty else { fail(usage) }

func seconds(_ duration: Duration) -> String {
    let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    return String(format: "%.3f s", value)
}

let snapshot = DictionarySnapshot(revision: 1, entries: words)
let engine = SpeechEngine(modelDirectory: model, storeDirectory: store, dictionary: { _ in snapshot })
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
