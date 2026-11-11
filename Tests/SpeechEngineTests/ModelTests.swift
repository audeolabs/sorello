import DictationCore
import DictionaryKit
import Foundation
import Testing
@testable import SpeechEngine

/// The real model, run only when `SORELLO_MODEL_DIR` points at the pinned bundle. Audio is synthetic speech made
/// with `say` from invented sentences, written to a temporary directory and deleted afterwards. The model store is
/// `SORELLO_MODEL_STORE`, or a directory under /tmp, so the Neural Engine's compiled model is reused between runs.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SORELLO_MODEL_DIR"] != nil), .serialized)
struct ModelTests {
    static var bundle: URL? {
        ProcessInfo.processInfo.environment["SORELLO_MODEL_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var store: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SORELLO_MODEL_STORE"] ?? "/tmp/sorello-speech-store/tests",
            isDirectory: true)
    }

    let sentence = "We moved the billing service to Vexlomar last week, and it works well."

    struct NoModel: Error {}

    func engine(_ entries: [DictionaryEntry] = []) async throws -> SpeechEngine {
        guard let bundle = Self.bundle else { throw NoModel() }
        let snapshot = DictionarySnapshot(revision: 1, entries: entries)
        let engine = SpeechEngine(modelDirectory: bundle, storeDirectory: Self.store,
                                  dictionary: { _ in snapshot })
        // The first load at a new store path compiles the model for the Neural Engine, which can take minutes.
        await prepare(engine, within: 1200)
        #expect(await ReadinessLog(engine).first(1) == [.ready])
        return engine
    }

    /// Synthetic speech of `text`, as 16 kHz samples.
    func speech(_ text: String) throws -> [Float] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("speech.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "--data-format=LEI16@16000", text]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0)
        return try AudioFileReader.samples(contentsOf: file)
    }

    /// Lowercased words without punctuation.
    func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    /// Word error rate of `hypothesis` against `reference`.
    func errorRate(_ hypothesis: String, _ reference: String) -> Double {
        let h = words(hypothesis), r = words(reference)
        var row = Array(0...h.count)
        for (i, word) in r.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: h.count)
            for j in 0..<h.count { next[j + 1] = min(row[j] + (word == h[j] ? 0 : 1), row[j + 1] + 1, next[j] + 1) }
            row = next
        }
        return Double(row[h.count]) / Double(max(r.count, 1))
    }

    @Test func transcribesSyntheticSpeech() async throws {
        let engine = try await engine()
        let text = try #require(await transcribe(engine, try speech("The quick brown fox jumps over the lazy dog."),
                                                 within: 120)).get()
        #expect(words(text) == ["the", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog"], "Heard \(text)")
        #expect(await transcribe(engine, Signals.zeros(2)) == .success(""), "Silence is empty text")
    }

    /// The app's path: 100 ms pieces appended while recording give the same text as the whole buffer.
    @Test func streamingEqualsWholeBuffer() async throws {
        let engine = try await engine()
        let samples = try speech(sentence)
        let stream = engine.openStream(SpeechStreamOptions())
        for start in stride(from: 0, to: samples.count, by: 1600) {
            stream.append(Array(samples[start..<min(start + 1600, samples.count)]))
        }
        let streamed = try #require(await finish(stream, within: 120)).get().text
        #expect(await transcribe(engine, samples, within: 120) == .success(streamed))
        #expect(errorRate(streamed, sentence) <= 0.15, "Heard \(streamed)")
    }

    /// Over 30 s: three chunks and two seams, joined without lost or doubled words.
    @Test func longRecordingIsJoinedAtSeams() async throws {
        let engine = try await engine()
        let text = """
            The committee met on a quiet Tuesday morning to review the plans for the new library. \
            Everyone agreed that the reading room should face the garden, and that the children's corner needs more \
            light. The architect showed three drawings, each with a different roof, and the group spent an hour \
            comparing them. After a short break they talked about the budget, the schedule for the builders, and how \
            to keep the old trees near the entrance. Before leaving, they chose the second drawing and asked for a \
            revised estimate by the end of the month. On the walk back, two of them stopped at the bakery on the \
            corner and argued, kindly, about whether the library should open on Sundays. One thought families would \
            come in the afternoon, and the other worried about the cost of extra staff. They promised to bring numbers \
            to the next meeting, which will be held in the town hall at the start of spring.
            """
        let samples = try speech(text)
        #expect(samples.count > 30 * 16_000, "The clip must be longer than two chunks")
        let heard = try #require(await transcribe(engine, samples, within: 120)).get()
        #expect(errorRate(heard, text) <= 0.08, "Heard \(heard)")
    }

    /// A made-up product name the model mishears on its own is recognized once the dictionary holds it.
    @Test func dictionaryBoostingChangesTheResult() async throws {
        let samples = try speech(sentence)
        let plain = try #require(await transcribe(try await engine(), samples, within: 120)).get()
        #expect(!words(plain).contains("vexlomar"), "Without the dictionary the name is misheard: \(plain)")
        let boosted = try #require(await transcribe(try await engine([DictionaryEntry(text: "Vexlomar", strength: 2)]),
                                                    samples, within: 120)).get()
        #expect(boosted.contains("Vexlomar"), "With the dictionary the name is heard, cased as the entry: \(boosted)")
    }

    /// The whole correction path: the dictation's audio is kept, the user corrects the misheard name, and the check
    /// decodes the same audio again with the name until it is heard.
    @Test func correctionFindsTheWord() async throws {
        let engine = try await engine()
        let stream = engine.openStream(SpeechStreamOptions(retainForCorrection: true))
        stream.append(try speech(sentence))
        let result = try #require(await finish(stream, within: 120)).get()
        let id = try #require(result.correctionID)
        // The user replaces whatever was heard between "to" and "last" with the name.
        var parts = result.text.components(separatedBy: " ")
        let index = try #require(parts.firstIndex(of: "to")) + 1
        try #require(index < parts.count && parts[index] != "Vexlomar", "Heard \(result.text)")
        parts[index] = "Vexlomar"
        let edited = parts.joined(separator: " "), check = engine.beginCorrectionCheck()
        let suggestion = await within(60) {
            await engine.suggestCorrection(typed: result.text, edited: edited, correctionID: id, ignore: [], isLast: true,
                                           check: check)
        } ?? nil
        #expect(suggestion?.word == "Vexlomar" && suggestion?.kind == .replace, "Got \(String(describing: suggestion))")
        #expect((suggestion?.strength ?? 0) >= 1 && (suggestion?.strength ?? 9) <= 8)
    }

    /// "Find strength" with the real model.
    @Test func probeFindsAStrength() async throws {
        let engine = try await engine()
        let samples = try speech(sentence)
        let probed = await within(120) { () -> StrengthProbe.Result? in
            try? await engine.probeStrength(samples: samples, word: "Vexlomar")
        } ?? nil
        let result = try #require(probed)
        guard case .recognized(let strength) = result.outcome else {
            Issue.record("Expected a strength, got \(result)")
            return
        }
        #expect(strength >= 1 && strength <= 8, "A strength on the verification ladder")
        #expect(result.boosted?.contains("Vexlomar") == true)
    }
}
