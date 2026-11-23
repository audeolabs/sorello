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

    @Test("A system that cannot list its devices goes by the processor: Apple silicon has a Neural Engine, Intel has not")
    func theProcessorDecidesWhereDevicesCannotBeListed() {
        #expect(SpeechCompute(appleSilicon: true) == .neuralEngine)
        #expect(SpeechCompute(appleSilicon: false) == .cpu)
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

#if SORELLO_LEGACY
/// The build for older Macs runs Sorello's own encoder on an Intel Mac (ARCHITECTURE.md, section 15, "The encoder on an
/// Intel Mac"). The processors are invented, so every kind is covered on whichever Mac runs this.
struct NativeComputeTests {
    let intel = NativeEncoderSupport(avx2: true, fma: true)

    @Test("An Intel processor with AVX2 and FMA runs Sorello's own encoder where Core ML's CPU kernels would run")
    func anIntelMacRunsTheNativeEncoder() {
        #expect(SpeechCompute(devices: [.cpu, .gpu]).preferringNative(intel) == .nativeCPU)
        #expect(SpeechCompute(devices: []).preferringNative(intel) == .nativeCPU)
        #expect(SpeechCompute(appleSilicon: false).preferringNative(intel) == .nativeCPU, "macOS 13, which lists no devices")
    }

    @Test func aNeuralEngineStillComesFirst() {
        #expect(SpeechCompute(devices: [.cpu, .gpu, .neuralEngine]).preferringNative(intel) == .neuralEngine)
        #expect(SpeechCompute(appleSilicon: true).preferringNative(intel) == .neuralEngine,
                "Rosetta may report AVX2, but the Mac has a Neural Engine")
    }

    @Test("Without AVX2 or FMA, Core ML's CPU kernels run, as before")
    func aProcessorWithoutAVX2OrFMAKeepsCoreML() {
        for support in [NativeEncoderSupport(avx2: false, fma: true), NativeEncoderSupport(avx2: true, fma: false),
                        NativeEncoderSupport(avx2: false, fma: false)] {
            #expect(SpeechCompute(devices: [.cpu, .gpu]).preferringNative(support) == .cpu)
            #expect(SpeechCompute(appleSilicon: false).preferringNative(support) == .cpu)
        }
    }

    @Test func thisMacsChoiceFollowsItsProcessor() {
        let compute = SpeechCompute.forThisMac()
        #expect(compute != .cpu || !NativeEncoderSupport.thisProcessor.isSupported)
        #expect(compute != .nativeCPU || NativeEncoderSupport.thisProcessor.isSupported)
    }

    @Test func itSaysWhatItIs() {
        #expect(SpeechCompute.nativeCPU.description == "CPU, Sorello's own encoder")
    }
}
#endif
