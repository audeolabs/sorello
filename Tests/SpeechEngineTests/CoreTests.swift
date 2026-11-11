import DictionaryKit
import Foundation
import Testing
@testable import SpeechEngine

/// The model-independent rules: buckets, words, the TDT decoder, chunks and seams. No model, audio or Core ML.
struct CoreTests {
    @Test func onlyTheFifteenSecondFunction() throws {
        #expect(SpeechCore.encoderSeconds == 15)
        #expect(SpeechCore.chunkSamples == 240_000)
        #expect(SpeechCore.chunkOverlapSamples == 32_000)
        for samples in [1, 480, 2 * 16_000, 4 * 16_000, 64_001, 7 * 16_000, 14 * 16_000, 240_000] {
            #expect(try SpeechCore.bucket(samples: samples) == 15)
        }
        for samples in [0, 240_001, 480_000] {
            #expect(throws: TranscriptionError.invalidAudio) { try SpeechCore.bucket(samples: samples) }
        }
    }

    @Test func wordsStartWhereTheirFirstTokenWasEmitted() throws {
        let tokens = [DecodedToken(id: 0, frame: 2), DecodedToken(id: 1, frame: 3), DecodedToken(id: 2, frame: 5)]
        #expect(try SpeechCore.words(tokens, vocabulary: ["▁Blue", "bird", "▁test."], offset: 100)
                == [HeardWord(text: "Bluebird", start: 100 + 2 * 1280), HeardWord(text: "test.", start: 100 + 5 * 1280)])
        #expect(throws: TranscriptionError.invalidModelOutput) {
            try SpeechCore.words([DecodedToken(id: 3, frame: 0)], vocabulary: ["▁test"], offset: 0)
        }
    }

    @Test func decoderSemantics() throws {
        // An emission whose duration reaches the end must still be returned.
        var predictions: [Int] = []
        let terminal = try SpeechCore.decode(length: 1, predict: { predictions.append($0) }, joint: { _ in (5, 4) },
                                             check: {})
        #expect(terminal == [DecodedToken(id: 5, frame: 0)])
        #expect(predictions == [1024, 5])

        // Zero-duration blanks and ten consecutive emissions must advance.
        var frames: [Int] = []
        let blanks = try SpeechCore.decode(length: 3, predict: { _ in }, joint: { frame in frames.append(frame); return (1024, 0) },
                                           check: {})
        #expect(blanks.isEmpty && frames == [0, 1, 2])
        let capped = try SpeechCore.decode(length: 2, predict: { _ in }, joint: { _ in (2, 0) }, check: {})
        #expect(capped.map(\.frame) == Array(repeating: 0, count: 10) + Array(repeating: 1, count: 10))
        #expect(throws: TranscriptionError.invalidModelOutput) {
            try SpeechCore.decode(length: 1, predict: { _ in }, joint: { _ in (1025, 0) }, check: {})
        }
        #expect(throws: TranscriptionError.invalidModelOutput) {
            try SpeechCore.decode(length: 1, predict: { _ in }, joint: { _ in (1, 5) }, check: {})
        }
        #expect(throws: CancellationError.self) {
            try SpeechCore.decode(length: 1, predict: { _ in }, joint: { _ in (1, 0) }, check: { throw CancellationError() })
        }
    }

    /// DESIGN §3.1: the biased decode keeps the unbiased loop and limits.
    @Test func biasedDecode() throws {
        // Deterministic synthetic logits; the unbiased path returns their plain argmax.
        var generator: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Float {
            generator = generator &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int(generator >> 40) % 2000 - 1000) / 100
        }
        let frames = 40
        var table: [[Float]] = []
        for frame in 0..<frames * 12 {
            var row = (0..<1030).map { _ in next() }
            row[1024] += frame % 3 == 0 ? 0 : 12  // mostly blanks, as real audio
            table.append(row)
        }
        func argmax(_ row: ArraySlice<Float>) -> Int {
            var best = row.startIndex
            for index in row.indices where row[index] > row[best] { best = index }
            return best - row.startIndex
        }
        func run(bias: BiasGraph?) throws -> [DecodedToken] {
            var calls = 0
            let buffer = FloatBuffer(count: 1030)
            if let bias {
                return try SpeechCore.decode(length: frames, bias: bias, predict: { _ in }, joint: { _ in
                    let row = table[calls % table.count]
                    calls += 1
                    for (index, value) in row.enumerated() { buffer.pointer[index] = value }
                    return (UnsafePointer(buffer.pointer), argmax(row[1025..<1030]))
                }, check: {})
            }
            return try SpeechCore.decode(length: frames, predict: { _ in }, joint: { _ in
                let row = table[calls % table.count]
                calls += 1
                return (argmax(row[0..<1025]), argmax(row[1025..<1030]))
            }, check: {})
        }
        let plain = try run(bias: nil)
        #expect(!plain.isEmpty, "Synthetic decode emits tokens")
        #expect(try run(bias: BiasGraph(phrases: [], tokens: 1024)) == plain)
        // Unrelated phrases (tokens never near the argmax) do not change the result.
        #expect(try run(bias: BiasGraph(phrases: [([1023, 1022], 0.25)], tokens: 1024)) == plain)
        #expect(try run(bias: BiasGraph(phrases: [([7], 4)], tokens: 1024)) != plain, "A strong boost changes decoding")

        // State advances on emissions only, so a two-token phrase gets its depth-2 bonus.
        let graph = try BiasGraph(phrases: [([1, 2], 1)], tokens: 1024)
        let scripted: [[Int: Float]] = [[1: 1, 1024: 0, 1025: 5], [1024: 1, 1025: 5], [2: 0, 1024: 4, 1025: 5]]
        var step = 0
        var predicted: [Int] = []
        let buffer = FloatBuffer(count: 1030)
        let tokens = try SpeechCore.decode(length: 3, bias: graph, predict: { predicted.append($0) }, joint: { _ in
            var row = [Float](repeating: -100, count: 1030)
            for (index, value) in scripted[step] { row[index] = value }
            step += 1
            for (index, value) in row.enumerated() { buffer.pointer[index] = value }
            return (UnsafePointer(buffer.pointer), 1)
        }, check: {})
        // Frame 2: 0 + 1.414 * (1 + 3 ln 2) = 4.35 beats the blank's 4.
        #expect(tokens == [DecodedToken(id: 1, frame: 0), DecodedToken(id: 2, frame: 2)])
        #expect(predicted == [1024, 1, 2])
        #expect(throws: TranscriptionError.invalidModelOutput) {
            try SpeechCore.decode(length: 1, bias: graph, predict: { _ in }, joint: { _ in (UnsafePointer(buffer.pointer), 5) },
                                  check: {})
        }
        #expect(throws: CancellationError.self) {
            try SpeechCore.decode(length: 1, bias: graph, predict: { _ in }, joint: { _ in (UnsafePointer(buffer.pointer), 1) },
                                  check: { throw CancellationError() })
        }
    }

    /// Silence must normalize to finite zero features without a model file.
    @Test func silentFeatures() throws {
        let frontend = try VDSPFrontEnd(window: [Float](repeating: 1, count: 400), fb: [Float](repeating: 0, count: 128 * 257))
        let silence = frontend.compute([Float](repeating: 0, count: 480))
        #expect(silence.valid == 3 && silence.frames == 4)
        #expect(silence.features.allSatisfy { $0.isFinite && $0 == 0 }, "Silence features must remain zero")
    }

    /// Model verification hashes files in bounded reads; the digest must match hashing the whole file at once.
    @Test func streamingDigest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.bin")
        let data = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try data.write(to: url)
        for chunkSize in [1, 4096, 5000, 10_000, 1 << 20] {
            #expect(try SpeechCore.sha256(fileURL: url, chunkSize: chunkSize) == SpeechCore.sha256(data))
        }
        #expect(try SpeechCore.sha256(fileURL: url, chunkSize: 4096) != SpeechCore.sha256(data.dropLast()),
                "A truncated file must not match")
        try Data().write(to: url)
        #expect(try SpeechCore.sha256(fileURL: url, chunkSize: 4096) == SpeechCore.sha256(Data()))
        #expect(throws: (any Error).self) { try SpeechCore.sha256(fileURL: directory.appendingPathComponent("missing.bin")) }
    }

    @Test func blobBounds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var value: Float = 1
        let data = withUnsafeBytes(of: &value) { Data($0) }
        try data.write(to: directory.appendingPathComponent("synthetic.f32bin"))
        func manifest(offset: Int = 0, shape: [Int] = [1], file: String = "synthetic.f32bin", sha: String? = nil) throws {
            let json: [String: Any] = ["file": file, "sha256": sha ?? SpeechCore.sha256(data),
                                       "tensors": [["name": "synthetic", "shape": shape, "offset": offset, "bytes": 4]]]
            try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("synthetic.json"))
        }
        try manifest()
        #expect(try NativeBlob(directory: directory, stem: "synthetic").tensor("synthetic", [1]) == [1])
        for bad in [{ try manifest(offset: -4) }, { try manifest(offset: 2) }, { try manifest(shape: [Int.max, Int.max]) },
                    { try manifest(file: "../synthetic.f32bin") }, { try manifest(sha: String(repeating: "0", count: 64)) }] {
            try bad()
            #expect(throws: TranscriptionError.invalidModelFile) { try NativeBlob(directory: directory, stem: "synthetic") }
        }
    }

    /// Preparation loads and warms only the 15 s function, once. A failed load or warm-up leaves nothing prepared and
    /// is retried by the next preparation, which keeps a model that loaded before the warm-up failed.
    @Test func modelCache() throws {
        final class SyntheticModel {}
        struct Failure: Error {}
        var loads: [Int] = [], warmed: [Int] = []
        func load(_ seconds: Int) -> SyntheticModel { loads.append(seconds); return SyntheticModel() }

        let cache = ModelCache<SyntheticModel>()
        #expect(!cache.isPrepared, "A new cache has nothing prepared")
        cache.prepare(load: load) { seconds, _ in warmed.append(seconds) }
        #expect(cache.isPrepared && loads == [15] && warmed == [15])
        let prepared = cache.model(load: load)
        cache.prepare(load: load) { _, _ in Issue.record("A prepared function must not warm twice") }
        #expect(cache.model(load: load) === prepared, "Transcription must reuse the prepared model")
        #expect(loads == [15] && warmed == [15])

        let failedWarmup = ModelCache<SyntheticModel>()
        loads = []; warmed = []
        #expect(throws: Failure.self) { try failedWarmup.prepare(load: load) { _, _ in throw Failure() } }
        #expect(!failedWarmup.isPrepared, "A failed warm-up must not mark the function ready")
        failedWarmup.prepare(load: load) { seconds, _ in warmed.append(seconds) }
        #expect(failedWarmup.isPrepared && loads == [15] && warmed == [15])

        let failedLoad = ModelCache<SyntheticModel>()
        loads = []; warmed = []
        #expect(throws: Failure.self) {
            try failedLoad.prepare(load: { _ in throw Failure() }) { _, _ in Issue.record("Nothing to warm") }
        }
        #expect(!failedLoad.isPrepared)
        failedLoad.prepare(load: load) { seconds, _ in warmed.append(seconds) }
        #expect(failedLoad.isPrepared && loads == [15] && warmed == [15])

        // A transcription can load the function before preparation runs; preparation reuses it.
        let early = ModelCache<SyntheticModel>()
        loads = []; warmed = []
        let existing = early.model(load: load)
        #expect(!early.isPrepared, "Loading alone must not mark the function ready")
        early.prepare(load: load) { seconds, _ in warmed.append(seconds) }
        #expect(loads == [15] && warmed == [15] && early.model(load: load) === existing)
    }

    /// Whole buffers and streamed audio reach the encoder as the same chunks.
    @Test func sharedChunking() {
        func chunks(_ samples: [Float], size: Int, overlap: Int = 0, read: Int) -> [AudioWindow] {
            var chunker = Chunker(size: size, overlap: overlap), result: [AudioWindow] = []
            for start in stride(from: 0, to: samples.count, by: read) {
                chunker.append(Array(samples[start..<min(start + read, samples.count)])) { result.append($0) }
                chunker.append([]) { _ in Issue.record("Empty reads must not emit chunks") }
            }
            chunker.finish { result.append($0) }
            chunker.finish { _ in Issue.record("A finished chunker must not emit again") }
            for chunk in result { #expect(chunk.samples == Array(samples[chunk.range]), "A chunk holds the audio at its range") }
            return result
        }
        let samples = (0..<10).map(Float.init)
        for read in [1, 3, 4, 7, 10] {
            #expect(chunks(samples, size: 4, read: read).map(\.samples) == [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9]])
            #expect(chunks(Array(samples.prefix(8)), size: 4, read: read).map(\.samples) == [[0, 1, 2, 3], [4, 5, 6, 7]])
            // Overlapping windows repeat the tail of the previous one. A final window is emitted only when it holds
            // audio no window covered yet.
            #expect(chunks(samples, size: 4, overlap: 1, read: read).map(\.range) == [0..<4, 3..<7, 6..<10])
            #expect(chunks(Array(samples.prefix(8)), size: 4, overlap: 1, read: read).map(\.range) == [0..<4, 3..<7, 6..<8])
            #expect(chunks(Array(samples.prefix(7)), size: 4, overlap: 1, read: read).map(\.range) == [0..<4, 3..<7])
            #expect(chunks(samples, size: 4, overlap: 2, read: read).map(\.range) == [0..<4, 2..<6, 4..<8, 6..<10])
            #expect(chunks(Array(samples.prefix(3)), size: 4, overlap: 1, read: read).map(\.range) == [0..<3])
        }
        #expect(chunks([], size: 4, read: 1).isEmpty)
        #expect(chunks([], size: 4, overlap: 2, read: 1).isEmpty)
        let recording = [Float](repeating: 0.25, count: 600_001)
        for read in [8192, recording.count] {
            #expect(chunks(recording, size: 240_000, read: read).map(\.samples.count) == [240_000, 240_000, 120_001])
            #expect(chunks(recording, size: 240_000, overlap: 32_000, read: read).map(\.range)
                    == [0..<240_000, 208_000..<448_000, 416_000..<600_001])
        }
        var failing = Chunker(size: 2, overlap: 1)
        #expect(throws: CancellationError.self) { try failing.append([1, 2, 3]) { _ in throw CancellationError() } }
    }

    /// Every recording, whatever its length, is cut into the same 15 s windows with a 2 s overlap, and each window
    /// runs on the 15 s function. A loud synthetic tone passes the silence compactor unchanged.
    @Test func recordingChunks() throws {
        func s(_ seconds: Int) -> Int { seconds * 16_000 }
        func chunks(_ seconds: Int) throws -> [Range<Int>] {
            let recording = Signals.tone(Double(seconds), level: -20)
            var transcription = ChunkedTranscription.recording(), ranges: [Range<Int>] = []
            func transcribe(_ chunk: AudioWindow) throws -> [HeardWord] {
                #expect(chunk.samples == Array(recording[chunk.range]))
                #expect(try SpeechCore.bucket(samples: chunk.samples.count) == 15)
                ranges.append(chunk.range)
                return []
            }
            for start in stride(from: 0, to: recording.count, by: 8192) {
                try transcription.append(Array(recording[start..<min(start + 8192, recording.count)]), transcribe: transcribe)
            }
            _ = try transcription.finish(transcribe: transcribe)
            return ranges
        }
        // Short dictations are one window, padded to the 15 s function.
        for seconds in [2, 4, 7, 14, 15] { #expect(try chunks(seconds) == [0..<s(seconds)]) }
        // Longer ones never use a longer window: windows start 13 s apart.
        #expect(try chunks(18) == [0..<s(15), s(13)..<s(18)])
        #expect(try chunks(28) == [0..<s(15), s(13)..<s(28)])
        #expect(try chunks(33) == [0..<s(15), s(13)..<s(28), s(26)..<s(33)])
        let long = try chunks(60)
        #expect(long == [0..<s(15), s(13)..<s(28), s(26)..<s(41), s(39)..<s(54), s(52)..<s(60)])
        for (earlier, later) in zip(long, long.dropFirst()) { #expect(earlier.upperBound - later.lowerBound == s(2)) }
    }

    /// Each chunk's model treats its edges as the start and end of speech. The shared audio must be stitched once,
    /// without the edge capitals, periods, or cut-off words that either chunk invented there.
    @Test func overlapReconciliation() {
        func s(_ seconds: Double) -> Int { Int(seconds * 16_000) }
        func w(_ text: String, _ seconds: Double) -> HeardWord { HeardWord(text: text, start: s(seconds)) }
        func stitched(_ chunks: [(Range<Int>, [HeardWord])]) -> String {
            var transcript = TranscriptAssembler()
            for (range, words) in chunks { transcript.append(words, covering: range) }
            return transcript.text
        }
        #expect(stitched([(0..<s(4), [w("Hello", 0.2), w("world.", 0.7)])]) == "Hello world.")
        #expect(stitched([]).isEmpty)
        // A false sentence break at the seam, and a cut-off word.
        #expect(stitched([
            (0..<s(15), [w("We", 11.5), w("walked", 12.0), w("to", 13.1), w("the", 13.4), w("store.", 13.8), w("And", 14.5),
                         w("th", 14.85)]),
            (s(13)..<s(17), [w("To", 13.12), w("the", 13.42), w("store", 13.84), w("and", 14.5), w("then", 15.0), w("home.", 15.4)]),
        ]) == "We walked to the store and then home.")
        // The seam word keeps the earlier chunk's casing and the later chunk's trailing punctuation.
        #expect(stitched([
            (0..<s(15), [w("We", 12.5), w("lived", 12.9), w("in", 13.5), w("Paris", 13.9), w("We", 14.6)]),
            (s(13)..<s(16), [w("In", 13.5), w("paris,", 13.95), w("we", 14.6), w("met.", 15.0)]),
        ]) == "We lived in Paris, we met.")
        // Repeated words pair in order.
        #expect(stitched([
            (0..<s(15), [w("said", 13.2), w("the", 13.95), w("the", 14.15), w("end.", 14.6)]),
            (s(13)..<s(16), [w("Said", 13.2), w("the", 13.9), w("the", 14.1), w("end", 14.6), w("today.", 15.2)]),
        ]) == "said the the end today.")
        // When one chunk misses a repetition, the remaining copy pairs with the copy heard at the same time.
        #expect(stitched([
            (0..<s(15), [w("very", 13.76), w("very", 14.0), w("good.", 14.88)]),
            (s(13)..<s(16), [w("Very", 14.04), w("good.", 14.92)]),
        ]) == "very very good.")
        // Without agreement the seam falls at the middle of the overlap.
        #expect(stitched([
            (0..<s(15), [w("alpha", 12.0), w("bravo", 13.5), w("charlie.", 14.5)]),
            (s(13)..<s(16), [w("Delta", 13.2), w("echo", 14.2), w("foxtrot.", 15.5)]),
        ]) == "alpha bravo echo foxtrot.")
        // Equal words heard at different times are different words.
        #expect(stitched([
            (0..<s(15), [w("one", 12.0), w("the", 13.1)]),
            (s(13)..<s(16), [w("The", 14.8), w("end.", 15.2)]),
        ]) == "one the The end.")
        // Silence in one chunk keeps only the other chunk's half of the overlap.
        #expect(stitched([(0..<s(15), [w("first", 10.0), w("late", 14.5)]), (s(13)..<s(16), [])]) == "first")
        // Chunks that do not overlap are concatenated, and each seam of a longer recording is reconciled on its own.
        #expect(stitched([(0..<s(4), [w("one", 1)]), (s(4)..<s(8), [w("Two", 5)])]) == "one Two")
        #expect(stitched([
            (0..<s(15), [w("Start", 1.0), w("of", 13.2), w("it.", 14.7)]),
            (s(13)..<s(28), [w("Of", 13.2), w("it", 14.7), w("goes", 15.2), w("on", 26.5), w("and.", 27.6)]),
            (s(26)..<s(29), [w("On", 26.5), w("and", 27.6), w("on.", 28.2)]),
        ]) == "Start of it goes on and on.")
    }
}
