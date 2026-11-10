import Foundation
import Testing
import TestSupport
@testable import SpeechEngine

/// The shared chunking vectors: silence compaction, chunk boundaries, words from tokens, seams and whole chunked
/// transcriptions. Signals are generated from the file's descriptions with exact arithmetic, so every platform sees
/// the same samples.
struct ChunkingVectorTests {
    /// One segment of a described signal: `["zeros", n]`, `["nan", n]`, `["constant", n, value]`,
    /// `["square", n, amplitude, period]` or `["noise", n, amplitude, seed]`.
    struct Segment: Decodable {
        let kind: String
        let count: Int
        let value: Double?
        let parameter: Int?

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            kind = try container.decode(String.self)
            count = try container.decode(Int.self)
            value = container.isAtEnd ? nil : try container.decode(Double.self)
            parameter = container.isAtEnd ? nil : try container.decode(Int.self)
        }
    }

    /// `[text, start]`.
    struct Word: Decodable {
        let word: HeardWord

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            word = HeardWord(text: try container.decode(String.self), start: try container.decode(Int.self))
        }
    }

    struct File: Decodable {
        struct Constants: Decodable {
            let alignmentTolerance, chunkOverlapSamples, chunkSamples, compactorFrameSamples, compactorInteriorPause,
                compactorMargin, compactorMaxPieceSamples, sampleRate, samplesPerEncoderFrame: Int
        }
        struct Compactor: Decodable {
            let name: String
            let signal: [Segment]
            let kept: [[Int]]
            let outputSamples: Int
            let margin: Int?
            let interiorPause: Int?
        }
        struct ChunkerCase: Decodable { let name: String; let total, size, overlap: Int; let chunks: [[Int]] }
        struct Words: Decodable {
            struct Case: Decodable {
                let name: String
                let tokens: [[Int]]
                let offset: Int
                let words: [Word]?
                let error: Bool?
            }
            let vocab: [String]
            let cases: [Case]
        }
        struct Assembler: Decodable {
            struct Append: Decodable { let range: [Int]; let words: [Word] }
            let name: String
            let appends: [Append]
            let text: String
        }
        struct Transcription: Decodable {
            let name: String
            let signal: [Segment]
            let every: Int
            let compact: Bool
            let size: Int?
            let overlap: Int?
            let chunks: [[Int]]
            let text: String
        }

        let version: Int
        let constants: Constants
        let compactorReads, chunkerReads, transcriptionReads: [[Int]]
        let compactor: [Compactor]
        let chunker: [ChunkerCase]
        let words: Words
        let assembler: [Assembler]
        let transcription: [Transcription]
    }

    let file: File

    init() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        file = try decoder.decode(File.self, from: Vectors.data("chunking-vectors.json"))
    }

    @Test func constants() {
        let constants = file.constants
        #expect(file.version == 1)
        #expect(constants.sampleRate == SpeechCore.sampleRate)
        #expect(constants.chunkSamples == SpeechCore.chunkSamples)
        #expect(constants.chunkOverlapSamples == SpeechCore.chunkOverlapSamples)
        #expect(constants.samplesPerEncoderFrame == SpeechCore.samplesPerEncoderFrame)
        #expect(constants.alignmentTolerance == TranscriptAssembler.alignmentTolerance)
        #expect(constants.compactorMargin == SilenceCompactor.defaultMargin)
        #expect(constants.compactorInteriorPause == SilenceCompactor.defaultInteriorPause)
        #expect(constants.compactorMaxPieceSamples == SilenceCompactor.maxPieceSamples)
        #expect(constants.compactorFrameSamples == SilenceCompactor.frameSamples)
        #expect(!file.compactor.isEmpty && !file.chunker.isEmpty && !file.words.cases.isEmpty && !file.assembler.isEmpty
                && !file.transcription.isEmpty)
    }

    @Test func compactor() {
        for item in file.compactor {
            let input = Self.signal(item.signal)
            var expected: [Float] = []
            for range in item.kept { expected += input[range[0]..<range[1]] }
            #expect(expected.count == item.outputSamples)
            for pattern in file.compactorReads {
                var compactor = SilenceCompactor(margin: item.margin ?? SilenceCompactor.defaultMargin,
                                                 interiorPause: item.interiorPause ?? SilenceCompactor.defaultInteriorPause)
                var output: [Float] = []
                var bounded = true
                let emit: ([Float]) -> Void = { piece in
                    bounded = bounded && !piece.isEmpty && piece.count <= SilenceCompactor.maxPieceSamples
                    output += piece
                }
                for part in Self.split(input, pattern) { compactor.append(part, emit: emit) }
                compactor.finish(emit: emit)
                #expect(bounded, "compactor \(item.name): unbounded piece")
                #expect(Self.same(output, expected), "compactor \(item.name) reads \(pattern)")
            }
        }
    }

    @Test func chunker() {
        for item in file.chunker {
            let input = (0..<item.total).map { Float($0) }
            for pattern in file.chunkerReads {
                var chunker = Chunker(size: item.size, overlap: item.overlap)
                var chunks: [[Int]] = []
                let emit: (AudioWindow) -> Void = { chunk in
                    #expect(Self.same(chunk.samples, Array(input[chunk.range])), "chunker \(item.name): samples")
                    chunks.append([chunk.start, chunk.samples.count])
                }
                for part in Self.split(input, pattern) { chunker.append(part, emit: emit) }
                chunker.finish(emit: emit)
                #expect(chunks == item.chunks, "chunker \(item.name) reads \(pattern)")
            }
        }
    }

    @Test func words() {
        for item in file.words.cases {
            let tokens = item.tokens.map { DecodedToken(id: $0[0], frame: $0[1]) }
            let result = try? SpeechCore.words(tokens, vocabulary: file.words.vocab, offset: item.offset)
            if item.error == true {
                #expect(result == nil, "words \(item.name) must fail")
            } else {
                #expect(result == item.words?.map(\.word), "words \(item.name)")
            }
        }
    }

    @Test func assembler() {
        for item in file.assembler {
            var assembler = TranscriptAssembler()
            for append in item.appends {
                assembler.append(append.words.map(\.word), covering: append.range[0]..<append.range[1])
            }
            #expect(assembler.text.unicodeScalars.elementsEqual(item.text.unicodeScalars), "assembler \(item.name)")
        }
    }

    @Test func transcription() {
        for item in file.transcription {
            let input = Self.signal(item.signal)
            for pattern in file.transcriptionReads {
                var transcription = item.compact
                    ? ChunkedTranscription.recording()
                    : ChunkedTranscription(size: item.size ?? SpeechCore.chunkSamples,
                                           overlap: item.overlap ?? SpeechCore.chunkOverlapSamples)
                var chunks: [[Int]] = []
                let transcribe: (AudioWindow) -> [HeardWord] = { chunk in
                    chunks.append([chunk.start, chunk.samples.count])
                    return Self.fakeWords(chunk, every: item.every)
                }
                for part in Self.split(input, pattern) { transcription.append(part, transcribe: transcribe) }
                let text = transcription.finish(transcribe: transcribe)
                #expect(chunks == item.chunks, "transcription \(item.name) reads \(pattern)")
                #expect(text == item.text, "transcription \(item.name) reads \(pattern)")
            }
        }
    }

    /// The file's fake recognizer: a word at every multiple of `every`, the chunk's first capitalized and its last
    /// ending in "."; none for silence.
    private static func fakeWords(_ chunk: AudioWindow, every: Int) -> [HeardWord] {
        if chunk.samples.allSatisfy({ $0 == 0 }) { return [] }
        var words = chunk.range.filter { $0 % every == 0 }.map { HeardWord(text: "w\($0 / every)", start: $0) }
        if let first = words.first { words[0] = HeardWord(text: "W" + first.text.dropFirst(), start: first.start) }
        if let last = words.last { words[words.count - 1] = HeardWord(text: last.text + ".", start: last.start) }
        return words
    }

    private static func signal(_ segments: [Segment]) -> [Float] {
        var samples: [Float] = []
        for segment in segments {
            let count = segment.count
            switch segment.kind {
            case "zeros": samples += [Float](repeating: 0, count: count)
            case "nan": samples += [Float](repeating: .nan, count: count)
            case "constant": samples += [Float](repeating: Float(segment.value ?? 0), count: count)
            case "square":
                let amplitude = Float(segment.value ?? 0), half = (segment.parameter ?? 2) / 2
                samples += (0..<count).map { ($0 / half) % 2 == 0 ? amplitude : -amplitude }
            case "noise":
                let amplitude = Float(segment.value ?? 0)
                var x = UInt64(segment.parameter ?? 0)
                for _ in 0..<count {
                    x ^= x << 13
                    x ^= x >> 7
                    x ^= x << 17
                    samples.append(Float(Int32(truncatingIfNeeded: x >> 32)) / 2_147_483_648 * amplitude)
                }
            default:
                Issue.record("Unknown signal segment \(segment.kind)")
            }
        }
        return samples
    }

    /// Appends of the pattern's sizes, repeated until the input is used up.
    private static func split(_ samples: [Float], _ pattern: [Int]) -> [[Float]] {
        guard !pattern.isEmpty else { return samples.isEmpty ? [] : [samples] }
        var parts: [[Float]] = [], start = 0, index = 0
        while start < samples.count {
            let end = min(start + pattern[index % pattern.count], samples.count)
            parts.append(Array(samples[start..<end]))
            start = end
            index += 1
        }
        return parts
    }

    private static func same(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }
    }
}
