import CoreML
import Foundation

/// Where the encoder runs (ARCHITECTURE.md, section 5). It is a fact about the hardware, read once when the engine is
/// made, never the architecture the app was built for: the Neural Engine on a Mac that has one, which is every Apple
/// silicon Mac, and Core ML's CPU kernels on one that has not, which is every Intel Mac. Both run the same model
/// files, chunks, front end and decoder. The GPU is never used, because nothing about it can be checked on the Macs
/// Sorello is built on.
public enum SpeechCompute: Sendable, Equatable, CustomStringConvertible {
    /// The Neural Engine, with the CPU for the layers it cannot run (`cpuAndNeuralEngine`).
    case neuralEngine
    /// Core ML's CPU kernels alone (`cpuOnly`): slower, with the 1-bit weights unpacked in memory.
    case cpu

    /// What this Mac's hardware offers, as Core ML reports it. The engine reads it once, when it is made; a forced
    /// choice (`--cpu` in the verification tools) is passed to the engine instead.
    public static func forThisMac() -> SpeechCompute {
        SpeechCompute(devices: MLComputeDevice.allComputeDevices.map { device in
            switch device {
            case .cpu: .cpu
            case .gpu: .gpu
            case .neuralEngine: .neuralEngine
            @unknown default: .other
            }
        })
    }

    /// A kind of compute device, as Core ML lists them.
    enum Device: Equatable {
        case cpu, gpu, neuralEngine
        /// A kind Core ML added after this was written; never chosen.
        case other
    }

    /// The choice for a Mac whose hardware lists `devices`: the Neural Engine if it is among them, otherwise the CPU,
    /// which every Mac has even when the list is empty.
    init(devices: [Device]) {
        self = devices.contains(.neuralEngine) ? .neuralEngine : .cpu
    }

    /// The compute units the encoder is loaded with.
    var computeUnits: MLComputeUnits {
        switch self {
        case .neuralEngine: .cpuAndNeuralEngine
        case .cpu: .cpuOnly
        }
    }

    /// "Neural Engine" or "CPU", for the verification tools' reports.
    public var description: String {
        switch self {
        case .neuralEngine: "Neural Engine"
        case .cpu: "CPU"
        }
    }
}
