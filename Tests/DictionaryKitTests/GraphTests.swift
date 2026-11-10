import Foundation
import Testing
@testable import DictionaryKit

/// The bias graph, its decision rule and casing restoration (DESIGN §1.2, §1.4).
struct GraphTests {
    private func expectedBonus(_ score: Double) -> Float { Float(1.414 * score) }

    private func own(_ sigma: Double, _ depth: Double) -> Double { sigma * (1 + 3 * log(depth)) }

    private func bonus(_ graph: BiasGraph, path: [Int], token: Int) -> Float {
        var state = BiasGraph.root
        for step in path where step >= 0 { state = graph.step(state, step).state }
        return graph.step(state, token).bonus
    }

    @Test func graphHandCases() throws {
        let g1 = try BiasGraph(phrases: [([1, 2, 3], 1)], tokens: 1024)
        expectULP(bonus(g1, path: [], token: 1), expectedBonus(own(1, 1)))
        expectULP(bonus(g1, path: [1], token: 2), expectedBonus(own(1, 2)))
        expectULP(bonus(g1, path: [1, 2], token: 3), expectedBonus(own(1, 3)))
        expectULP(bonus(g1, path: [], token: 9), 0)

        let g2 = try BiasGraph(phrases: [([1, 2, 3], 0.25), ([2, 3], 4)], tokens: 1024)
        expectULP(bonus(g2, path: [], token: 1), expectedBonus(own(0.25, 1)))
        expectULP(bonus(g2, path: [1], token: 2), expectedBonus(max(own(0.25, 2), own(4, 1))))
        expectULP(bonus(g2, path: [1, 2], token: 3), expectedBonus(max(own(0.25, 3), own(4, 2))))
        // Order-invariant.
        let g2r = try BiasGraph(phrases: [([2, 3], 4), ([1, 2, 3], 0.25)], tokens: 1024)
        expectULP(bonus(g2r, path: [1, 2], token: 3), bonus(g2, path: [1, 2], token: 3))

        let g3 = try BiasGraph(phrases: [([5, 6], 1), ([5, 6], 2)], tokens: 1024)
        expectULP(bonus(g3, path: [], token: 5), expectedBonus(own(2, 1)))
        expectULP(bonus(g3, path: [5], token: 6), expectedBonus(own(2, 2)))

        let g4 = try BiasGraph(phrases: [([1, 2], 1)], tokens: 1024)
        expectULP(bonus(g4, path: [1, -1], token: 2), expectedBonus(own(1, 2)))
        #expect(g4.step(g4.step(BiasGraph.root, 1).state, 1024).bonus == 0)
        let afterOne = g4.step(BiasGraph.root, 1).state
        #expect(g4.step(afterOne, 1024).state == afterOne, "The blank keeps the state")
        expectULP(bonus(g4, path: [1, 7], token: 2), 0)

        // Failure transitions land on the longest suffix state.
        let suffix = try BiasGraph(phrases: [([1, 2, 3], 1), ([2, 3, 4], 1)], tokens: 1024)
        expectULP(bonus(suffix, path: [1, 2, 3], token: 4), expectedBonus(own(1, 3)))

        for invalid: [([Int], Float)] in [[([1024], 1)], [([-2], 1)], [([1], .nan)], [([], 1)], [([1], 0)]] {
            #expect(throws: BiasGraphError.self) {
                try BiasGraph(phrases: invalid.map { (tokens: $0.0, strength: $0.1) }, tokens: 1024)
            }
        }
        #expect(try BiasGraph(phrases: [], tokens: 1024).isEmpty, "No phrases is empty")
    }

    @Test func decisionHandCases() throws {
        let logits = decisionLogits([1024: 5, 1: 3])
        let d1 = try BiasGraph(phrases: [([1], 1)], tokens: 1024)
        let d2 = try BiasGraph(phrases: [([1], 2)], tokens: 1024)
        let empty = try BiasGraph(phrases: [], tokens: 1024)
        logits.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            #expect(d1.biasedArgmax(state: BiasGraph.root, logits: base) == 1024)
            #expect(d2.biasedArgmax(state: BiasGraph.root, logits: base) == 1)
            #expect(empty.biasedArgmax(state: BiasGraph.root, logits: base) == 1024)
        }
        // First maximum wins, after the bonus is added in f64.
        decisionLogits([1: 1, 2: 1]).withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            #expect(empty.biasedArgmax(state: BiasGraph.root, logits: base) == 1)
        }
    }

    @Test func surfacesAndBuild() {
        let surfaces = BiasGraph.surfaces(of: "new York city")
        #expect(surfaces == [s("new York city"), s("new york city"), s("New York city"), s("New York City")],
                "Surfaces: text, fold, upper1, each word upper1")
        #expect(BiasGraph.surfaces(of: "kubernetes") == [s("kubernetes"), s("Kubernetes")],
                "Duplicate surfaces are removed")
        #expect(BiasGraph.build(entries: [], encoder: testEncoder) == nil, "An empty dictionary builds no graph")
        // Unencodable optional variants are skipped, never the whole entry.
        let lowerOnly = BPEEncoder(pieces: ["<unk>", "▁", "k", "u", "b", "e"])
        let graph = BiasGraph.build(entries: [entry("Kube")], encoder: lowerOnly)
        #expect(graph != nil, "The folded variant still encodes")
        #expect(graph.map { bonus($0, path: [1, 2, 3, 4], token: 5) > 0 } == true, "Folded variant is boosted")
    }

    @Test func casingHandCases() {
        let cases: [([String], String, String)] = [
            (["NixOS"], "i installed nixos on my laptop.", "i installed NixOS on my laptop."),
            (["iPhone"], "Iphone is new. my iphone works", "iPhone is new. my iPhone works"),
            (["kubectl"], "Kubectl get pods", "Kubectl get pods"),
            (["New York", "New York City"], "i live in new york city now", "i live in New York City now"),
            (["Rust"], "trusty rust_lang rust.", "trusty rust_lang Rust."),
            // Multi-word entries match single ASCII spaces only.
            (["New York"], "new  york and new\tyork", "new  york and new\tyork"),
            // A combining mark after the match is a word character.
            (["Rust"], "rust\u{301} rust", "rust\u{301} Rust"),
            // Replaced text is never rescanned; ties at equal length go by scalar order.
            (["AB", "Ab"], "ab", "AB"),
        ]
        for (entries, input, expected) in cases {
            expectScalars(CasingRestorer.apply(input, entries: entries.map { entry($0) }), expected)
        }
    }
}
