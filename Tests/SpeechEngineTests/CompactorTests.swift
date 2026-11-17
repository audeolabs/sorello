import Foundation
import Testing
@testable import SpeechEngine

/// Silence is shortened before chunking; speech must reach the model intact. Invented signals only.
struct CompactorTests {
    let margin = SilenceCompactor.defaultMargin
    let pause = SilenceCompactor.defaultInteriorPause
    var head: Int { pause / 2 }
    var tail: Int { pause - pause / 2 }

    private func s(_ seconds: Double) -> Int { Signals.s(seconds) }
    private func zeros(_ seconds: Double) -> [Float] { Signals.zeros(seconds) }
    private func tone(_ seconds: Double, level: Double, frequency: Double = 440) -> [Float] {
        Signals.tone(seconds, level: level, frequency: frequency)
    }
    private func noise(_ seconds: Double, level: Double, seed: UInt64) -> [Float] {
        Signals.noise(seconds, level: level, seed: seed)
    }
    private func compact(_ input: [Float], _ compactor: SilenceCompactor = .init(), reads: [Int] = []) -> [Float] {
        Signals.compact(input, compactor, reads: reads)
    }

    @Test func constants() {
        #expect(margin == s(0.3))
        #expect(pause >= 2 * margin, "A kept pause must hold both edge margins")
    }

    /// A whole recording appended at once is emitted in bounded pieces, so the compactor never builds a second
    /// full-size copy.
    @Test func boundedPieces() {
        let limit = SilenceCompactor.maxPieceSamples
        for (input, expected) in [(tone(60, level: -20), tone(60, level: -20)),
                                  (zeros(3) + tone(60, level: -20) + zeros(3), zeros(0.3) + tone(60, level: -20) + zeros(0.3)),
                                  (zeros(60), zeros(60))] {
            var compactor = SilenceCompactor(), pieces: [[Float]] = []
            compactor.append(input) { pieces.append($0) }
            compactor.finish { pieces.append($0) }
            #expect(pieces.count >= expected.count / limit, "A long recording must be emitted in several pieces")
            #expect(pieces.allSatisfy { !$0.isEmpty && $0.count <= limit }, "Every piece must be bounded")
            #expect(Array(pieces.joined()) == expected)
        }
    }

    /// A reader that can read its input again may have the compactor drop the silence it holds before any speech:
    /// what it holds stays bounded, and once speech comes the output is the same as without dropping. With no speech
    /// at all, dropping is reported, and `finish` says no speech was heard, so the caller knows to read again.
    @Test func droppingLeadingSilenceChangesNothingOnceSpeechComes() {
        let limit = s(15), piece = 8192
        let ragged = Array(tone(0.01, level: -20).prefix(37))
        for (input, hasSpeech) in [(noise(40, level: -50, seed: 3) + tone(5, level: -20) + zeros(3), true),
                                   (zeros(31) + tone(2, level: -20), true),
                                   (noise(20, level: -50, seed: 4) + ragged, true),
                                   (noise(40, level: -50, seed: 5), false)] {
            var compactor = SilenceCompactor(), output: [Float] = [], dropped = false, most = 0, start = 0
            while start < input.count {
                let end = min(start + piece, input.count)
                compactor.append(Array(input[start..<end])) { output += $0 }
                dropped = compactor.dropLeadingSilence(beyond: limit) || dropped
                most = max(most, compactor.heldSamples)
                start = end
            }
            let heard = compactor.finish { output += $0 }
            #expect(dropped, "The silence before speech outgrew the limit")
            #expect(most <= limit + piece + SilenceCompactor.frameSamples, "Held \(most) samples")
            #expect(heard == hasSpeech)
            if hasSpeech { #expect(output == compact(input), "The same output as without dropping") }
        }
        var speaking = SilenceCompactor()
        speaking.append(tone(1, level: -20) + zeros(30)) { _ in }
        let droppedAfterSpeech = speaking.dropLeadingSilence(beyond: limit)
        #expect(!droppedAfterSpeech, "After speech nothing is dropped")
    }

    /// Leading silence keeps its last margin, trailing silence its first, and a partial final frame of speech is kept.
    @Test func edges() {
        let speech = tone(1, level: -20)
        #expect(compact(zeros(2) + speech + zeros(2)) == zeros(0.3) + speech + zeros(0.3))
        #expect(compact(zeros(0.1) + speech + zeros(0.2)) == zeros(0.1) + speech + zeros(0.2))
        #expect(compact(speech) == speech)
        let ragged = tone(0.5, level: -20) + Array(tone(0.01, level: -20).prefix(37))
        #expect(compact(zeros(2) + ragged) == zeros(0.3) + ragged)
    }

    /// A pause longer than the kept pause becomes exactly the kept pause: its first half after speech and its last
    /// half before the next. Shorter pauses pass through untouched. The edges keep only a margin.
    @Test func interiorPauses() {
        let first = tone(1, level: -20, frequency: 300), second = tone(1, level: -20, frequency: 500)
        for (margin, pause) in [(s(0.3), s(0.6)), (s(0.3), s(0.8) + 1), (s(0.3), s(1.2)), (s(0.2), s(1)), (margin, pause)] {
            let compactor = SilenceCompactor(margin: margin, interiorPause: pause)
            let head = pause / 2, tail = pause - head
            // Silence-level noise shows which part of a pause is kept. Speech is decided per 10 ms frame.
            let frames = pause / 160 * 160
            for length in [s(0.1), frames - 160, frames, frames + 160, s(3), s(8)] {
                let gap = Array(noise(8, level: -75, seed: 13).prefix(length))
                let kept = length <= pause ? gap : Array(gap.prefix(head) + gap.suffix(tail))
                #expect(compact(first + gap + second, compactor) == first + kept + second)
                #expect(compact(zeros(4) + first + gap + second + zeros(4), compactor, reads: [4096])
                        == Array(zeros(4).suffix(margin)) + first + kept + second + Array(zeros(4).prefix(margin)))
            }
            // A pause is cut only where it is silent throughout: a click inside it is kept with a whole kept pause on
            // each side.
            let click = tone(0.01, level: -20), around = [Float](repeating: 0, count: pause)
            #expect(compact(first + zeros(4) + click + zeros(4) + second, compactor) == first + around + click + around + second)
        }
    }

    /// Quiet speech over a room's noise, a noisy fan and a low-gain microphone: the noise floor is learned, and the
    /// speech is kept with its margins.
    @Test func quietSpeechOverNoise() {
        for (floor, level) in [(-60.0, -35.0), (-50.0, -35.0), (-72.0, -45.0)] {
            var input = noise(8, level: floor, seed: 7)
            let burst = tone(1, level: level)
            Signals.add(burst, to: &input, at: s(2))
            Signals.add(burst, to: &input, at: s(5))
            let expected = Array(input[s(1.7)..<(s(3) + head)]) + Array(input[(s(5) - tail)..<s(6.3)])
            #expect(compact(input) == expected)
        }
        var input = noise(8, level: -60, seed: 3)
        Signals.add(noise(2, level: -30, seed: 4), to: &input, at: s(3))
        #expect(compact(input) == Array(input[s(2.7)..<s(5.3)]), "Noise-shaped speech is kept as well")
    }

    /// A long steady sound at speech level, or a held quiet vowel, is never learned as the noise floor and chopped.
    @Test func sustainedSound() {
        for (seconds, level) in [(10.0, -26.0), (4.0, -35.0), (12.0, -35.0), (20.0, -40.0)] {
            var input = noise(seconds + 4, level: -60, seed: 11)
            Signals.add(noise(seconds, level: level, seed: 12), to: &input, at: s(2))
            #expect(compact(input) == Array(input[s(1.7)..<s(2 + seconds + 0.3)]))
        }
    }

    /// Low-energy onsets and word endings stay inside the kept margins, including right after a long silence.
    @Test func weakOnsetsAndEndings() {
        let weak = noise(0.2, level: -65, seed: 5), speech = tone(1, level: -20)
        #expect(compact(zeros(4) + weak + speech + weak + zeros(4)) == zeros(0.1) + weak + speech + weak + zeros(0.1))
        #expect(compact(speech + zeros(5) + weak + speech)
                == speech + [Float](repeating: 0, count: pause - weak.count) + weak + speech)
    }

    /// Without speech the model hears the recording unchanged, and a finished compactor starts over.
    @Test func noSpeech() {
        #expect(compact([]).isEmpty)
        for input in [zeros(5), noise(5, level: -60, seed: 9), noise(5, level: -50, seed: 9), Array(zeros(1).prefix(1234)),
                      [Float(0.5)]] {
            #expect(compact(input) == input)
            #expect(compact(input, reads: [7, 160, 4096]) == input)
        }
        var compactor = SilenceCompactor()
        compactor.append(tone(1, level: -20) + zeros(1)) { _ in }
        compactor.finish { _ in }
        compactor.finish { _ in Issue.record("A finished compactor must not emit again") }
        var output: [Float] = []
        compactor.append(zeros(1)) { output += $0 }
        compactor.finish { output += $0 }
        #expect(output == zeros(1))
    }

    /// Invalid samples are not silence; they reach the model, which rejects them.
    @Test func invalidSamplesReachTheModel() {
        var gap = zeros(3)
        gap[s(1.5)] = .nan
        #expect(compact(tone(1, level: -20) + gap + tone(1, level: -20)).filter(\.isNaN).count == 1)
    }

    /// The same recording gives the same output however it is read.
    @Test func splitInvariance() {
        var input = noise(9, level: -55, seed: 21)
        Signals.add(tone(1.3, level: -30), to: &input, at: s(1.25) + 3)
        Signals.add(noise(0.4, level: -25, seed: 22), to: &input, at: s(2.95))
        Signals.add(tone(0.8, level: -40), to: &input, at: s(6.1) + 77)
        input += zeros(1) + tone(0.5, level: -20) + Array(zeros(0.01).prefix(91))
        let whole = compact(input)
        #expect(whole.count < input.count, "The fixture must contain compacted silence")
        for reads in [[1], [7], [159], [160], [161], [4096], [8192], [3, 500, 1, 16_000, 160]] {
            #expect(compact(input, reads: reads) == whole)
        }
    }

    /// A chunked transcription with a compactor chunks the compacted audio: any split into appends gives the chunks
    /// and text of one append, and the chunks cover the compacted audio exactly.
    @Test func chunkedTranscription() {
        let input = zeros(1) + tone(2, level: -20) + zeros(4) + tone(1.5, level: -20, frequency: 300) + zeros(2)
        let compacted = compact(input)
        #expect(compacted.count < input.count, "The fixture must contain compacted silence")
        func transcribe(_ reads: [Int]) -> (text: String, chunks: [AudioWindow]) {
            var transcription = ChunkedTranscription(size: s(1), overlap: s(0.25), compactor: SilenceCompactor())
            var chunks: [AudioWindow] = [], start = 0, index = 0
            func words(_ chunk: AudioWindow) -> [HeardWord] {
                chunks.append(chunk)
                return [HeardWord(text: "w\(chunk.start).", start: chunk.start)]
            }
            repeat {
                let end = min(start + (reads.isEmpty ? input.count : reads[index % reads.count]), input.count)
                transcription.append(Array(input[start..<end]), transcribe: words)
                start = end
                index += 1
            } while start < input.count
            return (transcription.finish(transcribe: words), chunks)
        }
        let whole = transcribe([])
        #expect(whole.chunks.first?.start == 0)
        #expect(whole.chunks.last?.range.upperBound == compacted.count)
        #expect(whole.chunks.allSatisfy { Array(compacted[$0.range]) == $0.samples },
                "Every chunk must hold the compacted audio at its range")
        for reads in [[1], [160], [4096], [s(3)], [3, 500, 16_000, 7]] {
            let split = transcribe(reads)
            #expect(split.chunks == whole.chunks && split.text == whole.text)
        }
    }
}
