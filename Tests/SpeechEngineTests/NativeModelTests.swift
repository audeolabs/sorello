#if SORELLO_LEGACY
import DictationCore
import DictionaryKit
import Foundation
import Testing
@testable import SpeechEngine

/// Sorello's own encoder against Core ML's CPU kernels on the real model (ARCHITECTURE.md, section 15, "The encoder on
/// an Intel Mac"), run only when `SORELLO_MODEL_DIR` points at the build for macOS 13. Audio is synthetic speech.
extension ModelTests {
    /// Gate 4's measure: the error's norm against the reference's, and its largest value against the reference's
    /// root mean square, with the research repository's floor.
    static func gateErrors(_ a: EncoderFrames, _ r: EncoderFrames) -> (relative: Double, absolute: Double) {
        var difference = 0.0, reference = 0.0, largest = 0.0
        for t in 0..<r.count {
            for h in 0..<1024 {
                let x = Double(a.base[t * a.timeStride + h * a.hiddenStride])
                let y = Double(r.base[t * r.timeStride + h * r.hiddenStride])
                difference += (x - y) * (x - y)
                reference += y * y
                largest = max(largest, abs(x - y))
            }
        }
        let n = Double(r.count * 1024), tau = 1e-3
        return (difference.squareRoot() / max(reference.squareRoot(), tau * n.squareRoot()),
                largest / max((reference / n).squareRoot(), tau))
    }

    @Test("Sorello's own encoder hears what Core ML's CPU kernels hear, within gate 4's ceilings")
    func theNativeEncoderMatchesCoreML() throws {
        let bundle = try #require(Self.bundle)
        let coreML = try CoreMLSpeechModel(directory: bundle, compute: .cpu)
        try coreML.prepare()
        let native = try CoreMLSpeechModel(directory: bundle, compute: .nativeCPU)
        try native.prepare()
        #expect(native.nativeKernel != nil, "The build's program has what Sorello's own encoder needs")
        #expect(coreML.nativeKernel == nil)
        let library = try speech(Self.library)
        // A short dictation, and a full 15 s chunk.
        for samples in [try speech(sentence), Array(library.prefix(SpeechCore.chunkSamples))] {
            let r = try #require(try coreML.encoderFrames(samples, check: {}))
            let a = try #require(try native.encoderFrames(samples, check: {}))
            #expect(a.count == r.count)
            let errors = Self.gateErrors(a, r)
            #expect(errors.relative <= 0.02, "relative \(errors.relative)")
            #expect(errors.absolute <= 0.25, "absolute \(errors.absolute)")
        }
    }

    @Test func theNativeEncoderGivesTheSameText() async throws {
        let library = try speech(Self.library)
        let coreML = try await engine(compute: .cpu)
        let native = try await engine(compute: .nativeCPU)
        for samples in [try speech(sentence), library] {
            let expected = try await coreML.transcribe(samples)
            #expect(try await native.transcribe(samples) == expected)
        }
        #expect(await native.nativeKernel() != nil)
    }
}
#endif
