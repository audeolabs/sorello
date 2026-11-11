import DictationCore
import DictionaryKit
import Foundation
import Testing
@testable import SpeechEngine

/// Where the encoder runs (ARCHITECTURE.md, section 5): the Neural Engine where the hardware has one, otherwise
/// Core ML's CPU kernels. The device lists are invented, so every kind of Mac is covered on whichever one runs this.
struct ComputeTests {
    @Test func aMacWithANeuralEngineUsesIt() {
        #expect(SpeechCompute(devices: [.cpu, .gpu, .neuralEngine]) == .neuralEngine)
        #expect(SpeechCompute(devices: [.neuralEngine, .cpu]) == .neuralEngine, "The order the system lists them in does not matter")
        #expect(SpeechCompute(devices: [.neuralEngine]) == .neuralEngine)
    }

    @Test func aMacWithoutOneUsesTheCPUAndNeverTheGPU() {
        #expect(SpeechCompute(devices: [.cpu, .gpu]) == .cpu, "An Intel Mac: a processor and a graphics card")
        #expect(SpeechCompute(devices: [.cpu, .gpu, .gpu]) == .cpu, "An Intel Mac with two graphics cards")
        #expect(SpeechCompute(devices: [.cpu]) == .cpu)
    }

    @Test func aMacThatReportsNothingUsesTheCPU() {
        #expect(SpeechCompute(devices: []) == .cpu)
    }

    @Test func theEngineReadsTheHardwareUnlessToldOtherwise() {
        let dictionary: @Sendable (String?) -> DictionarySnapshot = { _ in .empty }
        #expect(SpeechEngine(modelDirectory: nil, storeDirectory: nil, dictionary: dictionary).compute
                == SpeechCompute.forThisMac())
        #expect(SpeechEngine(modelDirectory: nil, storeDirectory: nil, compute: .cpu, dictionary: dictionary).compute
                == .cpu)
        #expect(SpeechEngine(modelDirectory: nil, storeDirectory: nil, compute: .neuralEngine,
                             dictionary: dictionary).compute == .neuralEngine)
    }

    @Test func eachChoiceSaysWhatItIs() {
        #expect(SpeechCompute.neuralEngine.description == "Neural Engine")
        #expect(SpeechCompute.cpu.description == "CPU")
    }
}
