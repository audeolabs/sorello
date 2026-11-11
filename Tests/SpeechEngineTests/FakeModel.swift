import DictationCore
import DictionaryKit
import Foundation
import Synchronization
@testable import SpeechEngine

/// What a fake model did, readable from the test while the engine works.
final class ModelLog: Sendable {
    private struct State {
        var loads = 0
        var projected: [Int] = []
        var decodes = 0
    }

    private let state = Mutex(State())

    var loads: Int { state.withLock { $0.loads } }
    /// The sample count of every chunk projected, in order.
    var projected: [Int] { state.withLock { $0.projected } }
    var decodes: Int { state.withLock { $0.decodes } }

    func loaded() { state.withLock { $0.loads += 1 } }
    func project(_ count: Int) { state.withLock { $0.projected.append(count) } }
    func decoded() { state.withLock { $0.decodes += 1 } }
}

/// A model that hears a word at every whole second of its input, named by the second: "w3" at 3 s. A chunk's first
/// word is capitalized and its last ends with a period, as the real model does at chunk edges, so seams are joined
/// as they are for speech. With a bias graph that boosts "zorblax" at strength 2 or more, it hears "zorblax" for "w1".
final class FakeModel: SpeechModel {
    static let pieces = ["<unk>", "▁"] + "abcdefghijklmnopqrstuvwxyzW0123456789.".map { String($0) }
    /// The bonus a depth-2 node earns at strength 2 (DESIGN §1.2), less a margin for rounding.
    static let threshold = Float(1.414 * 2 * (1 + 3 * Foundation.log(2.0))) - 0.001
    let encoder = BPEEncoder(pieces: FakeModel.pieces)
    private let log: ModelLog
    private let projectDelay: TimeInterval

    init(log: ModelLog, projectDelay: TimeInterval = 0) {
        self.log = log
        self.projectDelay = projectDelay
    }

    func project(_ samples: [Float], check: () throws -> Void) throws -> Projection? {
        try check()
        guard samples.allSatisfy(\.isFinite) else { throw TranscriptionError.invalidAudio }
        guard samples.count <= SpeechCore.chunkSamples else { throw TranscriptionError.invalidAudio }
        if samples.allSatisfy({ $0 == 0 }) { return nil }
        if projectDelay > 0 { Thread.sleep(forTimeInterval: projectDelay) }
        log.project(samples.count)
        return Projection(buffer: FloatBuffer(samples), frames: samples.count, bytes: samples.count * 4)
    }

    func decode(_ projection: Projection, offset: Int, bias: BiasGraph?, check: () throws -> Void) throws -> [HeardWord] {
        try check()
        log.decoded()
        let boosted = bias.map { boost(of: "zorblax", in: $0) >= Self.threshold } ?? false
        let seconds = (offset..<(offset + projection.frames)).filter { $0 % 16_000 == 0 }
        return seconds.enumerated().map { index, position in
            var text = position == 16_000 && boosted ? "zorblax" : "w\(position / 16_000)"
            if index == 0 { text = text.prefix(1).uppercased() + text.dropFirst() }
            if index == seconds.count - 1 { text += "." }
            return HeardWord(text: text, start: position)
        }
    }

    /// The bonus a graph gives the second token of `word`, which only that word's phrases reach.
    private func boost(of word: String, in graph: BiasGraph) -> Float {
        let tokens = encoder.encode(word)
        guard tokens.count > 1 else { return 0 }
        return graph.step(graph.step(BiasGraph.root, tokens[0]).state, tokens[1]).bonus
    }
}

/// Loads a fake model after an optional delay or wait, failing the first `failures` times with `failure`.
func fakeLoader(_ log: ModelLog, failures: Int = 0, failure: EngineFailure = .loadFailed, delay: TimeInterval = 0,
                wait: DispatchSemaphore? = nil, projectDelay: TimeInterval = 0) -> ModelLoader {
    { () throws(EngineFailure) -> any SpeechModel in
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        wait?.wait()
        log.loaded()
        if log.loads <= failures { throw failure }
        return FakeModel(log: log, projectDelay: projectDelay)
    }
}

/// The fake model, except that its first projection, when it `holds`, waits for `release()` after saying it has
/// `entered()`, so a test can act while the model is busy with a chunk. Every projection is counted once it has ended,
/// whether it returned or threw.
final class HeldModel: SpeechModel, Sendable {
    let encoder = BPEEncoder(pieces: FakeModel.pieces)
    private let log: ModelLog
    private let holds: Bool
    private let arrived = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let ended = Mutex(0)

    init(log: ModelLog, holds: Bool = true) {
        self.log = log
        self.holds = holds
    }

    /// Projections that have ended.
    var projections: Int { ended.withLock { $0 } }

    /// Returns once the first projection is waiting.
    func entered() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.arrived.wait()
                continuation.resume()
            }
        }
    }

    /// Lets the first projection go on.
    func release() { gate.signal() }

    func project(_ samples: [Float], check: () throws -> Void) throws -> Projection? {
        if holds && projections == 0 {
            arrived.signal()
            gate.wait()
        }
        defer { ended.withLock { $0 += 1 } }
        return try FakeModel(log: log).project(samples, check: check)
    }

    func decode(_ projection: Projection, offset: Int, bias: BiasGraph?, check: () throws -> Void) throws -> [HeardWord] {
        try FakeModel(log: log).decode(projection, offset: offset, bias: bias, check: check)
    }
}
