import Foundation
import Testing
import TestSupport
@testable import DictionaryKit

/// The shared dictionary vectors (DESIGN §1.7), read by Sorello and the Linux implementation alike. Every section
/// that applies to the Mac runs here.
struct VectorTests {
    struct Phrase: Decodable { let tokens: [Int]; let strength: Double }
    struct EntryVector: Decodable { let text: String; let strength: Double }

    struct File: Decodable {
        struct Constants: Decodable {
            let alpha, contextScore, depthScaling: Double
            let blank: Int
            let verifyStrengths: [Double]
            enum CodingKeys: String, CodingKey {
                case alpha, blank, contextScore = "context_score", depthScaling = "depth_scaling"
                case verifyStrengths = "verify_strengths"
            }
        }
        struct Encode: Decodable { let text: String; let tokens: [Int] }
        struct Validation: Decodable { let text: String; let strength: Double?; let ok: Bool; let normalized: String?; let error: String? }
        struct Phrases: Decodable { let name: String; let entries: [EntryVector]; let phrases: [Phrase] }
        struct Graph: Decodable {
            struct Step: Decodable { let path: [Int]; let token: Int; let bonus: Double }
            let name: String
            let phrases: [Phrase]
            let steps: [Step]
        }
        struct Decision: Decodable {
            let name: String
            let phrases: [Phrase]
            let path: [Int]
            let logits: [String: Double]
            let expectedToken: Int
            enum CodingKeys: String, CodingKey { case name, phrases, path, logits, expectedToken = "expected_token" }
        }
        struct Casing: Decodable { let entries: [String]; let transcript: String; let expected: String }
        struct Candidates: Decodable {
            struct Expected: Decodable {
                let surface: String
                let kind: String
                let beforeRange: [Int]
                let beforeWords: [String]
                enum CodingKeys: String, CodingKey {
                    case surface, kind, beforeRange = "before_range", beforeWords = "before_words"
                }
            }
            let before, after: String
            let dictionary, ignore: [String]
            let expected: [Expected]
        }
        struct Verify: Decodable {
            let name, before, after, base: String
            let candidateIndex: Int
            let decoded: [String: String]
            let expectedStrength: Double?
            enum CodingKeys: String, CodingKey {
                case name, before, after, base = "B", candidateIndex = "candidate_index", decoded = "N_by_strength"
                case expectedStrength = "expected_strength"
            }
        }
        struct Key: Decodable { let key: String; let valid: Bool; let from: String? }

        let version: Int
        let constants: Constants
        let vocab: [String]
        let encode: [Encode]
        let validation: [Validation]
        let phrases: [Phrases]
        let graph: [Graph]
        let decision: [Decision]
        let casing: [Casing]
        let candidates: [Candidates]
        let verify: [Verify]
        let keys: [Key]
    }

    let file: File
    let encoder: BPEEncoder

    init() throws {
        file = try Vectors.decode(File.self, from: "dictionary-vectors.json")
        encoder = BPEEncoder(pieces: file.vocab)
    }

    @Test func constants() {
        #expect(file.version == 1)
        #expect(file.constants.alpha == BiasGraph.alpha)
        #expect(file.constants.contextScore == BiasGraph.contextScore)
        #expect(file.constants.depthScaling == BiasGraph.depthScaling)
        #expect(file.constants.blank == BPEEncoder.vocabularySize)
        #expect(file.constants.verifyStrengths.map(Float.init) == VerifyDecision.strengths)
        for section in [file.encode.count, file.validation.count, file.phrases.count, file.graph.count, file.decision.count,
                        file.casing.count, file.candidates.count, file.verify.count, file.keys.count] {
            #expect(section > 0, "Every section has cases")
        }
    }

    @Test func encode() {
        for item in file.encode {
            #expect(encoder.encode(item.text) == item.tokens, "encode \(item.text.debugDescription)")
        }
    }

    @Test func validation() {
        for item in file.validation {
            let strength = Float(item.strength ?? 1)
            let result = DictionaryValidation.validate(text: item.text, strength: strength, encoder: encoder)
            switch result {
            case .success(let entry):
                #expect(item.ok, "validation \(item.text.debugDescription) must fail")
                expectScalars(entry.text, item.normalized ?? "")
                #expect(entry.strength == strength)
            case .failure(let error):
                #expect(!item.ok && error.rawValue == item.error, "validation \(item.text.debugDescription): \(error)")
            }
        }
    }

    @Test func phrases() {
        for item in file.phrases {
            let entries = item.entries.map { DictionaryEntry(text: $0.text, strength: Float($0.strength)) }
            let actual = BiasGraph.phrases(entries: entries, encoder: encoder).sorted { $0.tokens.lexicographicallyPrecedes($1.tokens) }
            #expect(actual.map(\.tokens) == item.phrases.map(\.tokens), "phrases \(item.name)")
            #expect(actual.map(\.strength) == item.phrases.map { Float($0.strength) }, "phrases \(item.name)")
        }
    }

    @Test func graph() throws {
        for item in file.graph {
            let graph = try BiasGraph(phrases: item.phrases.map { ($0.tokens, Float($0.strength)) }, tokens: 1024)
            for step in item.steps {
                var state = BiasGraph.root
                for token in step.path where token >= 0 { state = graph.step(state, token).state }
                expectULP(graph.step(state, step.token).bonus, Float(step.bonus))
            }
        }
    }

    @Test func decision() throws {
        for item in file.decision {
            let graph = try BiasGraph(phrases: item.phrases.map { ($0.tokens, Float($0.strength)) }, tokens: 1024)
            var state = BiasGraph.root
            for token in item.path where token >= 0 { state = graph.step(state, token).state }
            var values: [Int: Float] = [:]
            for (key, value) in item.logits {
                values[try #require(Int(key))] = Float(value)
            }
            let token = decisionLogits(values).withUnsafeBufferPointer { buffer in
                buffer.baseAddress.map { graph.biasedArgmax(state: state, logits: $0) }
            }
            #expect(token == item.expectedToken, "decision \(item.name)")
        }
    }

    @Test func casing() {
        for item in file.casing {
            expectScalars(CasingRestorer.apply(item.transcript, entries: item.entries.map { entry($0) }), item.expected)
        }
    }

    @Test func candidates() throws {
        for item in file.candidates {
            let found = CorrectionCandidates.find(before: item.before, after: item.after,
                                                  dictionary: item.dictionary.map { entry($0) },
                                                  ignore: Set(item.ignore.map(DictionaryKey.init)), encoder: encoder)
            let expected = try item.expected.map { candidate in
                CorrectionCandidate(surface: candidate.surface, kind: try #require(CorrectionKind(rawValue: candidate.kind)),
                                    beforeRange: candidate.beforeRange[0]..<candidate.beforeRange[1],
                                    beforeWords: candidate.beforeWords.map { s($0) })
            }
            #expect(found == expected, "candidates \(item.before.prefix(60))")
        }
    }

    @Test func verify() throws {
        for item in file.verify {
            let found = CorrectionCandidates.find(before: item.before, after: item.after, dictionary: [], ignore: [],
                                                  encoder: encoder)
            try #require(found.indices.contains(item.candidateIndex), "verify \(item.name): no candidate")
            let candidate = found[item.candidateIndex]
            var accepted: Float?
            if candidate.kind == .casing {
                accepted = DictionaryValidation.defaultStrength
            } else {
                for strength in VerifyDecision.strengths {
                    let n = item.decoded[Self.strengthKey(strength)] ?? item.base
                    if VerifyDecision.accepts(typed: item.before, candidate: candidate, base: item.base, decoded: n) {
                        accepted = strength
                        break
                    }
                }
            }
            #expect(accepted == item.expectedStrength.map(Float.init), "verify \(item.name)")
        }
    }

    /// Pin P6: stored identity and ignore keys.
    @Test func keys() {
        for item in file.keys {
            let key = DictionaryKey(folded: s(item.key))
            #expect(key.isValid == item.valid, "key of \(s(item.key).count) scalars")
            if let from = item.from { #expect(DictionaryKey(from) == key, "fold(from) must equal the key") }
            // Valid keys round-trip through the file; invalid ones are never saved or loaded.
            var dictionary = CustomDictionary()
            #expect((dictionary.addIgnore(key) == nil) == key.isValid, "Only valid keys are saved")
            #expect((DictionaryFile.decode(fileData(ignore: [item.key]), encoder: encoder) != nil) == key.isValid,
                    "Only valid keys load")
        }
    }

    /// The vector keys: "1.0", "1.41", "2.0", "2.83", "4.0", "5.66", "8.0".
    private static func strengthKey(_ strength: Float) -> String {
        let text = DictionaryValidation.label(strength).dropFirst()
        return text.contains(".") ? String(text) : text + ".0"
    }
}
