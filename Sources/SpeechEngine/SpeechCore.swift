import CryptoKit
import DictionaryKit
import Foundation

// The model-independent rules of transcription: how audio is cut into chunks, how tokens become words, how the TDT
// decoder steps, and how chunk transcripts are joined. They are pure, so they are tested without the model, and the
// shared vectors in Tests/Vectors pin them on every platform.

/// Why a chunk or a file could not be turned into words. Content-free: nothing here names audio, text or a path.
enum TranscriptionError: Error, Equatable {
    /// The stream or the call was cancelled.
    case cancelled
    /// The audio held a sample that is not a finite number, or a chunk of an impossible size.
    case invalidAudio
    /// The model returned something the decoder cannot use.
    case invalidModelOutput
    /// A model file is not shaped as the code expects.
    case invalidModelFile
}

enum SpeechCore {
    static let sampleRate = 16_000
    /// The one encoder function Sorello runs (`b15`). The Neural Engine holds memory for every loaded function, so no
    /// other is ever loaded.
    static let encoderSeconds = 15
    /// Recordings are split into windows of at most this many samples, each one pass of the 15 s function.
    static let chunkSamples = encoderSeconds * sampleRate
    /// 10 ms features, subsampled 8x by the encoder.
    static let samplesPerEncoderFrame = 1280
    /// Consecutive chunks share this much audio, so the seam between them can be placed where both chunks heard the
    /// speech with context on each side.
    static let chunkOverlapSamples = 2 * sampleRate
    /// The blank row of the decoder's token logits.
    static let blank = 1024

    static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// Bounded reads keep a large encoder out of memory while it is verified.
    static func sha256(fileURL: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        // Drain each chunk's autoreleased buffer before reading the next.
        while try autoreleasepool(invoking: {
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The encoder function, in seconds, that runs a chunk of `samples`: always the 15 s one, with shorter chunks
    /// zero-padded.
    static func bucket(samples: Int) throws(TranscriptionError) -> Int {
        guard samples > 0, samples <= chunkSamples else { throw .invalidAudio }
        return encoderSeconds
    }

    /// Whitespace-separated words, each starting at the recording sample where its first token was emitted.
    /// `offset` is the chunk's first sample.
    static func words(_ tokens: [DecodedToken], vocabulary: [String],
                      offset: Int) throws(TranscriptionError) -> [HeardWord] {
        guard tokens.allSatisfy({ vocabulary.indices.contains($0.id) }) else { throw .invalidModelOutput }
        var words: [HeardWord] = [], text = "", start = 0
        for token in tokens {
            for character in vocabulary[token.id].replacingOccurrences(of: "▁", with: " ") {
                if character.isWhitespace {
                    if !text.isEmpty { words.append(HeardWord(text: text, start: start)) }
                    text = ""
                } else {
                    if text.isEmpty { start = offset + token.frame * samplesPerEncoderFrame }
                    text.append(character)
                }
            }
        }
        if !text.isEmpty { words.append(HeardWord(text: text, start: start)) }
        return words
    }

    /// Greedy TDT decoding with NeMo's semantics, including terminal emissions and the per-frame symbol cap.
    /// `predict` feeds a token to the prediction network; `joint` returns the token and duration decided at a frame.
    static func decode(length: Int, predict: (Int) throws -> Void, joint: (Int) throws -> (Int, Int),
                       check: () throws -> Void) throws -> [DecodedToken] {
        try decode(length: length, predict: predict, decide: { frame, _ in try joint(frame) },
                   advance: { state, _ in state }, check: check)
    }

    /// Biased greedy TDT decoding (DESIGN §3.1): the same loop and limits as the unbiased decode, but the token is the
    /// f64 biased argmax over the exposed logits, and the bias state follows non-blank emissions.
    static func decode(length: Int, bias: BiasGraph, predict: (Int) throws -> Void,
                       joint: (Int) throws -> (logits: UnsafePointer<Float>, duration: Int),
                       check: () throws -> Void) throws -> [DecodedToken] {
        precondition(bias.tokens == blank, "The bias graph must cover the model vocabulary")
        return try decode(length: length, predict: predict, decide: { frame, state in
            let (logits, duration) = try joint(frame)
            return (bias.biasedArgmax(state: state, logits: logits), duration)
        }, advance: { bias.step($0, $1).state }, check: check)
    }

    /// The loop both decoders share. `decide` returns the token and duration at a frame from the bias state;
    /// `advance` moves the bias state past an emitted token.
    private static func decode(length: Int, predict: (Int) throws -> Void,
                               decide: (_ frame: Int, _ state: Int) throws -> (Int, Int),
                               advance: (_ state: Int, _ token: Int) -> Int,
                               check: () throws -> Void) throws -> [DecodedToken] {
        var tokens: [DecodedToken] = [], frame = 0, lastFrame = -1, symbols = 0, state = BiasGraph.root
        try predict(blank)
        while frame < length {
            try check()
            let (token, duration) = try decide(frame, state)
            guard (0...blank).contains(token), (0...4).contains(duration) else {
                throw TranscriptionError.invalidModelOutput
            }
            var move = token == blank && duration == 0 ? 1 : duration
            if token != blank {
                symbols = lastFrame == frame ? symbols + 1 : 1
                lastFrame = frame
                tokens.append(DecodedToken(id: token, frame: frame))
                state = advance(state, token)
                try predict(token)
                if move == 0 && symbols >= 10 { move = 1 }
            }
            frame += move
        }
        return tokens
    }
}

/// A token the decoder emitted, and the encoder frame it was emitted at.
struct DecodedToken: Equatable {
    let id: Int
    let frame: Int
}

/// A word of a chunk's transcript.
struct HeardWord: Equatable {
    let text: String
    /// Sample of the model input (the recording with silence compacted) where the word's first token was emitted.
    let start: Int
}

/// A window of the recording, starting at sample `start`.
struct AudioWindow: Equatable {
    let samples: [Float]
    let start: Int
    var range: Range<Int> { start..<(start + samples.count) }
}

/// Windows of exactly `size` samples that start `size - overlap` apart. Only the final one may be shorter, and it is
/// emitted only when it holds audio no earlier window covered. A whole buffer and audio streamed while recording
/// share it, so both split the same audio at the same boundaries.
struct Chunker {
    let size: Int
    let overlap: Int
    private var pending: [Float] = []
    private var carried = 0
    private var start = 0

    init(size: Int, overlap: Int) {
        precondition(size > 0, "Chunk size must be positive")
        // Each overlap then ends before the next begins, so a seam only ever involves two chunks.
        precondition(overlap >= 0 && 2 * overlap <= size, "Chunk overlap must be at most half the chunk size")
        self.size = size
        self.overlap = overlap
    }

    mutating func append(_ samples: [Float], emit: (AudioWindow) throws -> Void) rethrows {
        var rest = samples[...]
        while pending.count + rest.count >= size {
            let take = size - pending.count
            let window = AudioWindow(samples: pending + rest.prefix(take), start: start)
            pending = Array(window.samples.suffix(overlap))
            carried = pending.count
            start += size - overlap
            rest = rest.dropFirst(take)
            try emit(window)
        }
        pending.append(contentsOf: rest)
    }

    mutating func finish(emit: (AudioWindow) throws -> Void) rethrows {
        let window = AudioWindow(samples: pending, start: start)
        let fresh = pending.count > carried
        pending = []
        carried = 0
        if fresh { try emit(window) }
    }
}

/// One recording split into chunks, each transcribed as soon as it is complete, and joined. Whole buffers and
/// streams both run it, so however the samples arrive they give the same chunks, seams and text. With a compactor,
/// silence is shortened before chunking, so chunk ranges are positions in the compacted audio.
struct ChunkedTranscription {
    private var compactor: SilenceCompactor?
    private var chunker: Chunker
    private var transcript = TranscriptAssembler()

    init(size: Int, overlap: Int, compactor: SilenceCompactor? = nil) {
        self.compactor = compactor
        chunker = Chunker(size: size, overlap: overlap)
    }

    /// How every dictation is split, whatever its length: silence compacted, then 15 s windows that overlap by 2 s.
    static func recording() -> ChunkedTranscription {
        ChunkedTranscription(size: SpeechCore.chunkSamples, overlap: SpeechCore.chunkOverlapSamples,
                             compactor: SilenceCompactor())
    }

    mutating func append(_ samples: [Float], transcribe: (AudioWindow) throws -> [HeardWord]) rethrows {
        try Self.append(samples, &compactor, &chunker, &transcript, transcribe)
    }

    /// Transcribes the remaining partial chunk, if it holds new audio, and returns the text.
    mutating func finish(transcribe: (AudioWindow) throws -> [HeardWord]) rethrows -> String {
        try Self.finish(&compactor, &chunker, &transcript, transcribe)
        return transcript.text
    }

    // Separate inout properties: a closure capturing self would overlap the chunker's access.
    private static func append(_ samples: [Float], _ compactor: inout SilenceCompactor?, _ chunker: inout Chunker,
                               _ transcript: inout TranscriptAssembler,
                               _ transcribe: (AudioWindow) throws -> [HeardWord]) rethrows {
        guard var active = compactor else { return try chunk(samples, &chunker, &transcript, transcribe) }
        // Moved out and back, so the compactor's buffers are never shared and never copied.
        compactor = nil
        defer { compactor = active }
        try active.append(samples) { try chunk($0, &chunker, &transcript, transcribe) }
    }

    private static func finish(_ compactor: inout SilenceCompactor?, _ chunker: inout Chunker,
                               _ transcript: inout TranscriptAssembler,
                               _ transcribe: (AudioWindow) throws -> [HeardWord]) rethrows {
        if var active = compactor {
            compactor = nil
            defer { compactor = active }
            try active.finish { try chunk($0, &chunker, &transcript, transcribe) }
        }
        try chunker.finish { transcript.append(try transcribe($0), covering: $0.range) }
    }

    private static func chunk(_ samples: [Float], _ chunker: inout Chunker, _ transcript: inout TranscriptAssembler,
                              _ transcribe: (AudioWindow) throws -> [HeardWord]) rethrows {
        try chunker.append(samples) { transcript.append(try transcribe($0), covering: $0.range) }
    }
}

/// Joins chunk transcripts in recording order. A chunk's model treats its edges as the start and end of speech, so
/// it may capitalize, punctuate, or cut off words there. Where two chunks overlap, the seam is placed on a word both
/// heard, near the middle of the shared audio: earlier words come from the earlier chunk and later words from the
/// later one.
struct TranscriptAssembler {
    /// Starts of the same word in two chunks differ by a few encoder frames.
    static let alignmentTolerance = 6400
    private var words: [HeardWord] = []
    private var end: Int?

    var text: String { words.map(\.text).joined(separator: " ") }

    mutating func append(_ chunkWords: [HeardWord], covering range: Range<Int>) {
        if let end, range.lowerBound < end {
            words = Self.merge(words, chunkWords, overlap: range.lowerBound..<end)
        } else {
            words += chunkWords
        }
        end = range.upperBound
    }

    private static func merge(_ left: [HeardWord], _ right: [HeardWord], overlap: Range<Int>) -> [HeardWord] {
        let tolerance = alignmentTolerance
        let l = left.indices.filter { left[$0].start >= overlap.lowerBound - tolerance }
        let r = right.indices.filter { right[$0].start < overlap.upperBound + tolerance }
        let leftKeys = l.map { key(left[$0].text) }, rightKeys = r.map { key(right[$0].text) }
        func distance(_ x: Int, _ y: Int) -> Int { abs(left[l[x]].start - right[r[y]].start) }
        func matches(_ x: Int, _ y: Int) -> Bool {
            !leftKeys[x].isEmpty && leftKeys[x] == rightKeys[y] && distance(x, y) <= tolerance
        }
        // Longest common subsequence, so repeated words pair in order. Among equally long alignments, the one whose
        // pairs are closest in time wins.
        typealias Alignment = (count: Int, cost: Int)
        func better(_ a: Alignment, _ b: Alignment) -> Bool { a.count != b.count ? a.count > b.count : a.cost < b.cost }
        var best: [[Alignment]] = Array(repeating: Array(repeating: (count: 0, cost: 0), count: r.count + 1),
                                        count: l.count + 1)
        func paired(_ x: Int, _ y: Int) -> Alignment {
            (best[x + 1][y + 1].count + 1, best[x + 1][y + 1].cost + distance(x, y))
        }
        for x in l.indices.reversed() {
            for y in r.indices.reversed() {
                let skip = better(best[x][y + 1], best[x + 1][y]) ? best[x][y + 1] : best[x + 1][y]
                best[x][y] = matches(x, y) && better(paired(x, y), skip) ? paired(x, y) : skip
            }
        }
        var pairs: [(Int, Int)] = [], x = 0, y = 0
        while x < l.count, y < r.count {
            if matches(x, y), paired(x, y) == best[x][y] {
                pairs.append((l[x], r[y]))
                x += 1
                y += 1
            } else if best[x + 1][y] == best[x][y] {
                x += 1
            } else {
                y += 1
            }
        }
        let middle = overlap.lowerBound + overlap.upperBound
        guard let anchor = pairs.min(by: {
            abs(left[$0.0].start + right[$0.1].start - middle) < abs(left[$1.0].start + right[$1.1].start - middle)
        }) else {
            return left.filter { 2 * $0.start < middle } + right.filter { 2 * $0.start >= middle }
        }
        let (i, j) = anchor
        return Array(left[..<i]) + [seam(left[i], right[j])] + right[(j + 1)...]
    }

    /// Casing comes from the earlier chunk, which heard what preceded the word; trailing punctuation from the later
    /// chunk, which heard what follows it.
    private static func seam(_ left: HeardWord, _ right: HeardWord) -> HeardWord {
        let leftScalars = left.text.unicodeScalars, rightScalars = right.text.unicodeScalars
        guard let leftEnd = leftScalars.lastIndex(where: CharacterSet.alphanumerics.contains),
              let rightEnd = rightScalars.lastIndex(where: CharacterSet.alphanumerics.contains) else { return left }
        let text = String(leftScalars[...leftEnd]) + String(rightScalars[rightScalars.index(after: rightEnd)...])
        return HeardWord(text: text, start: left.start)
    }

    private static func key(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }
}

/// Holds the 15 s encoder function: loaded once and kept, and prepared once its synthetic warm-up succeeds. A failed
/// load or warm-up is retried by the next preparation. Used from one isolation domain only.
final class ModelCache<Model> {
    private var loaded: Model?
    private(set) var isPrepared = false

    /// The 15 s function, loaded on first use.
    func model(load: (Int) throws -> Model) rethrows -> Model {
        if let loaded { return loaded }
        let model = try load(SpeechCore.encoderSeconds)
        loaded = model
        return model
    }

    /// Loads the function if needed and warms it; does nothing once prepared.
    func prepare(load: (Int) throws -> Model, warm: (Int, Model) throws -> Void) rethrows {
        guard !isPrepared else { return }
        try warm(SpeechCore.encoderSeconds, try model(load: load))
        isPrepared = true
    }
}
