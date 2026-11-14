import Foundation

// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.

/// A dictionary phrase was not a valid path in the graph: empty, with a token outside the vocabulary, or with a
/// strength that is not finite and positive.
public struct BiasGraphError: Error, Equatable, Sendable {}

/// How the dictionary biases decoding (DESIGN §1.2): an Aho-Corasick trie over token ids with per-entry strengths.
/// A token that continues a dictionary phrase earns a bonus added to its logit. Immutable after construction, so one
/// graph serves every decode of a dictionary snapshot; the decoder keeps its own state.
public final class BiasGraph: Sendable {
    static let alpha = 1.414
    static let contextScore = 1.0
    static let depthScaling = 3.0
    /// The state before any phrase has started.
    public static let root = 0

    /// Non-blank vocabulary size; the blank is row `tokens`.
    public let tokens: Int
    private let children: [[Int: Int]]
    private let fail: [Int]
    /// α · score(n), computed in f64 and stored as f32.
    private let bonus: [Float]
    /// Bonuses for every row from the root, the end of every failure chain.
    private let rootRow: [Float]

    var isEmpty: Bool { children.count == 1 }

    /// Builds the trie from token sequences. Throws if any phrase is empty, has a token outside `0..<tokens`, or a
    /// strength that is not finite and positive.
    public init(phrases: [(tokens: [Int], strength: Float)], tokens: Int) throws(BiasGraphError) {
        self.tokens = tokens
        var children: [[Int: Int]] = [[:]]
        var depth = [0]
        var sigma: [Double] = [0]
        for phrase in phrases {
            guard !phrase.tokens.isEmpty, phrase.strength.isFinite, phrase.strength > 0,
                  phrase.tokens.allSatisfy({ (0..<tokens).contains($0) }) else {
                throw BiasGraphError()
            }
            let strength = Double(phrase.strength)
            var node = Self.root
            for token in phrase.tokens {
                if let next = children[node][token] {
                    node = next
                } else {
                    children.append([:])
                    depth.append(depth[node] + 1)
                    sigma.append(0)
                    children[node][token] = children.count - 1
                    node = children.count - 1
                }
                // σ: the strongest phrase passing through or ending at the node.
                sigma[node] = max(sigma[node], strength)
            }
        }
        var fail = [Int](repeating: Self.root, count: children.count)
        var score = [Double](repeating: 0, count: children.count)
        // Breadth-first, so each failure target is final before it is read.
        var queue = children[Self.root].values.sorted()
        var head = 0
        while head < queue.count {
            let node = queue[head]
            head += 1
            let own = sigma[node] * (Self.contextScore + Self.depthScaling * log(Double(depth[node])))
            score[node] = max(own, score[fail[node]])
            for (token, child) in children[node].sorted(by: { $0.key < $1.key }) {
                fail[child] = Self.transition(children, fail, from: fail[node], token: token)
                queue.append(child)
            }
        }
        let bonus = score.map { Float(Self.alpha * $0) }
        var rootRow = [Float](repeating: 0, count: tokens + 1)
        for (token, child) in children[Self.root] { rootRow[token] = bonus[child] }
        self.children = children
        self.fail = fail
        self.bonus = bonus
        self.rootRow = rootRow
    }

    /// The deepest state reached by `token` from `state` or the first of its suffixes that has a transition.
    private static func transition(_ children: [[Int: Int]], _ fail: [Int], from state: Int, token: Int) -> Int {
        var state = state
        while true {
            if let next = children[state][token] { return next }
            if state == Self.root { return Self.root }
            state = fail[state]
        }
    }

    /// `goto(state, token)` and the bonus for taking a non-blank token there. The blank keeps the state and earns
    /// nothing.
    public func step(_ state: Int, _ token: Int) -> (state: Int, bonus: Float) {
        guard token != tokens else { return (state, 0) }
        let next = Self.transition(children, fail, from: state, token: token)
        return (next, next == Self.root ? 0 : bonus[next])
    }

    /// The decision rule: argmax over rows 0...tokens of f64(logit) + f64(bonus), the first maximum winning.
    /// `logits` must hold at least `tokens + 1` finite values.
    public func biasedArgmax(state: Int, logits: UnsafePointer<Float>) -> Int {
        // Only tokens with a transition from the state or its suffixes get a bonus; the deepest state on the failure
        // chain decides each token. Start from the root's row and overwrite from shallow to deep.
        var row = rootRow
        var chain: [Int] = []
        var node = state
        while node != Self.root {
            chain.append(node)
            node = fail[node]
        }
        for node in chain.reversed() {
            for (token, child) in children[node] { row[token] = bonus[child] }
        }
        var best = 0
        var bestValue = Double(logits[0]) + Double(row[0])
        for index in 1...tokens {
            let value = Double(logits[index]) + Double(row[index])
            if value > bestValue { best = index; bestValue = value }
        }
        return best
    }

    /// Phrase surfaces of an entry, deduplicated by scalars: the text, its fold, `upper1`, and every word through
    /// `upper1`.
    static func surfaces(of text: String) -> [[Unicode.Scalar]] {
        let scalars = Array(text.unicodeScalars)
        let words = scalars.split(separator: " ", omittingEmptySubsequences: false)
        var eachWord: [Unicode.Scalar] = []
        for (index, word) in words.enumerated() {
            if index > 0 { eachWord.append(" ") }
            eachWord += DictionaryText.upper1(word)
        }
        var result: [[Unicode.Scalar]] = []
        for surface in [scalars, DictionaryText.fold(scalars), DictionaryText.upper1(scalars), eachWord]
        where !result.contains(surface) {
            result.append(surface)
        }
        return result
    }

    /// The graph for `entries`, or nil when no surface encodes, including an empty dictionary: decoding then takes
    /// the unbiased path.
    public static func build(entries: [DictionaryEntry], encoder: BPEEncoder) -> BiasGraph? {
        let list = phrases(entries: entries, encoder: encoder)
        guard !list.isEmpty else { return nil }
        return try? BiasGraph(phrases: list, tokens: BPEEncoder.vocabularySize)
    }

    /// The token sequences an entry list boosts, in first-seen order: each entry's surfaces, then each of its
    /// spellings' surfaces at its strength (DESIGN §3.7). Surfaces with <unk> are skipped; duplicate sequences keep the
    /// largest strength.
    static func phrases(entries: [DictionaryEntry], encoder: BPEEncoder) -> [(tokens: [Int], strength: Float)] {
        var strengths: [[Int]: Float] = [:]
        var order: [[Int]] = []
        for entry in entries {
            for surface in ([entry.text] + entry.soundsLike).flatMap(surfaces(of:)) {
                let tokens = encoder.encode(DictionaryText.string(surface))
                guard !tokens.isEmpty, !tokens.contains(BPEEncoder.unknownID) else { continue }
                if let existing = strengths[tokens] {
                    strengths[tokens] = max(existing, entry.strength)
                } else {
                    strengths[tokens] = entry.strength
                    order.append(tokens)
                }
            }
        }
        return order.compactMap { tokens in strengths[tokens].map { (tokens, $0) } }
    }
}
