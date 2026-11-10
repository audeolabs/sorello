import Foundation

// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.

/// The speech model's vocabulary file could not be read as one.
public struct VocabularyError: Error, Equatable, Sendable {}

/// SentencePiece BPE encoding over Unicode scalars (DESIGN §1.3, pin P4): how a dictionary word is spelled in the
/// model's tokens, and whether the model can spell it at all. A piece's id is its merge rank: lower ids merge first.
/// Pieces are keyed by exact scalar sequence, never by `String`, so canonically equivalent text does not collapse
/// onto one piece. Immutable, so one encoder serves every thread.
public final class BPEEncoder: Sendable {
    static let unknownID = 0
    static let wordBoundary: Unicode.Scalar = "\u{2581}"
    /// The model's vocabulary size, without the blank.
    public static let vocabularySize = 1024

    private let ids: [[Unicode.Scalar]: Int]

    /// Pieces in id order. `<unk>` and empty pieces are never produced from text; a repeated piece keeps its lowest
    /// id.
    public init(pieces: [String]) {
        var ids: [[Unicode.Scalar]: Int] = [:]
        for (id, piece) in pieces.enumerated() {
            let scalars = Array(piece.unicodeScalars)
            guard !scalars.isEmpty, !scalars.elementsEqual("<unk>".unicodeScalars), ids[scalars] == nil else { continue }
            ids[scalars] = id
        }
        self.ids = ids
    }

    /// The model bundle's `vocabulary.json`, shaped `{"0": piece, …, "1023": piece}`: at most 1 MiB with exactly
    /// 1024 keys. The numeric order is the rank.
    public convenience init(vocabularyFile url: URL) throws(VocabularyError) {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw VocabularyError() }
        try self.init(pieces: Self.pieces(vocabulary: data))
    }

    /// The pieces of a `vocabulary.json` in id order.
    static func pieces(vocabulary data: Data) throws(VocabularyError) -> [String] {
        guard data.count <= 1 << 20,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              object.count == vocabularySize else {
            throw VocabularyError()
        }
        var pieces: [String] = []
        for id in 0..<vocabularySize {
            guard let piece = object[String(id)] else { throw VocabularyError() }
            pieces.append(piece)
        }
        return pieces
    }

    /// The token ids of `text`.
    public func encode(_ text: String) -> [Int] {
        // Empty text still gets the dummy prefix (pin P7), as SentencePiece does.
        var symbols: [[Unicode.Scalar]] = [[Self.wordBoundary]]
        for scalar in text.unicodeScalars {
            symbols.append([scalar == " " ? Self.wordBoundary : scalar])
        }
        // Inputs are at most a few hundred scalars, so a quadratic scan is cheap and keeps the tie rule (lowest id,
        // then leftmost) obvious.
        while symbols.count > 1 {
            var best: (index: Int, id: Int)?
            for index in 0..<(symbols.count - 1) {
                guard let id = ids[symbols[index] + symbols[index + 1]] else { continue }
                if let current = best, current.id <= id { continue }
                best = (index, id)
            }
            guard let best else { break }
            symbols[best.index] += symbols[best.index + 1]
            symbols.remove(at: best.index + 1)
        }
        var tokens: [Int] = []
        var previousUnknown = false
        for symbol in symbols {
            if let id = ids[symbol] {
                tokens.append(id)
                previousUnknown = false
            } else {
                // A run of non-pieces is one <unk>.
                if !previousUnknown { tokens.append(Self.unknownID) }
                previousUnknown = true
            }
        }
        return tokens
    }

    /// Whether the model can spell `text`: it encodes to at least one token and none is `<unk>`.
    public func encodesWithoutUnknown(_ text: String) -> Bool {
        let tokens = encode(text)
        return !tokens.isEmpty && !tokens.contains(Self.unknownID)
    }
}
