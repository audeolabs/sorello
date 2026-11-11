import CoreML
import DictationCore
import DictionaryKit
import Foundation

/// One chunk's encoder output after the joint's encoder-side projection: what decoding needs, and what a correction
/// check decodes again. Owned memory, not a view on Core ML's.
final class Projection {
    let buffer: FloatBuffer
    let frames: Int
    /// The memory it holds, counted against the retention limit.
    let bytes: Int

    init(buffer: FloatBuffer, frames: Int, bytes: Int) {
        self.buffer = buffer
        self.frames = frames
        self.bytes = bytes
    }
}

/// What the engine needs from a loaded model. The Core ML runtime implements it; tests use a fake, so the engine's
/// streams, preparation and retention are tested without the model. Used only on the engine's executor.
protocol SpeechModel: AnyObject {
    /// The model's vocabulary, for dictionary phrases.
    var encoder: BPEEncoder { get }
    /// The encoder and joint projection of one chunk of at most 15 s; nil for digital silence.
    func project(_ samples: [Float], check: () throws -> Void) throws -> Projection?
    /// The words of one projected chunk, timed from `offset`, the chunk's first sample, biased by `bias` if there is
    /// one.
    func decode(_ projection: Projection, offset: Int, bias: BiasGraph?, check: () throws -> Void) throws -> [HeardWord]
}

/// The bundled model: a Core ML encoder holding the 15 s function, run on the Neural Engine, with the native front end
/// and decoder. Every file is checked against the manifest's SHA-256 before anything is loaded.
final class CoreMLSpeechModel: SpeechModel {
    /// The files every bundle must list, beside the encoder.
    static let requiredFiles = ["frontend.json", "frontend.f32bin", "decoder_joint.json", "decoder_joint.f32bin",
                                "vocabulary.json"]

    let directory: URL
    let encoder: BPEEncoder
    private let frontend: VDSPFrontEnd
    private let math: NativeMath
    private let vocabulary: [String]
    private let models = ModelCache<MLModel>()

    /// Verifies the bundle at `directory` and reads its native parts. The encoder is loaded by `prepare`.
    init(directory: URL) throws(EngineFailure) {
        self.directory = directory
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("bundle.json")) else {
            throw .modelMissing
        }
        guard let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = manifest["files"] as? [String: String],
              Self.requiredFiles.allSatisfy({ files[$0] != nil }),
              files.keys.contains(where: { $0.hasPrefix("Encoder.mlmodelc/") }),
              (manifest["sample_rate"] as? Int).map({ $0 == SpeechCore.sampleRate }) ?? true,
              (manifest["buckets_seconds"] as? [Int]).map({ $0.contains(SpeechCore.encoderSeconds) }) ?? true else {
            throw .modelCorrupt
        }
        for (name, digest) in files {
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { throw .modelCorrupt }
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw .modelMissing }
            guard (try? SpeechCore.sha256(fileURL: url)) == digest else { throw .modelCorrupt }
        }
        do {
            frontend = try VDSPFrontEnd(constantsDirectory: directory)
            math = NativeMath(try NativeWeights(directory: directory))
            guard let vocabularyData = try? Data(contentsOf: directory.appendingPathComponent("vocabulary.json")) else {
                throw TranscriptionError.invalidModelFile
            }
            vocabulary = try BPEEncoder.vocabularyPieces(from: vocabularyData)
        } catch {
            throw .modelCorrupt
        }
        encoder = BPEEncoder(pieces: vocabulary)
    }

    /// Loads the 15 s encoder function on the Neural Engine and warms it with invented zero features. No audio or
    /// user content is read.
    func prepare() throws(EngineFailure) {
        do {
            try models.prepare(load: loadEncoder, warm: Self.warm)
        } catch {
            throw .loadFailed
        }
    }

    private func loadEncoder(seconds: Int) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        configuration.functionName = "b\(seconds)"
        return try MLModel(contentsOf: directory.appendingPathComponent("Encoder.mlmodelc"), configuration: configuration)
    }

    private static func warm(seconds: Int, model: MLModel) throws {
        let size = seconds * 100 + 1
        let mel = try MLMultiArray(shape: [1, 128, NSNumber(value: size)], dataType: .float32)
        mel.dataPointer.bindMemory(to: Float.self, capacity: mel.count).initialize(repeating: 0, count: mel.count)
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: size)
        _ = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": mel, "mel_length": length]))
    }

    func project(_ input: [Float], check: () throws -> Void) throws -> Projection? {
        try check()
        guard input.allSatisfy(\.isFinite) else { throw TranscriptionError.invalidAudio }
        if input.allSatisfy({ $0 == 0 }) { return nil }
        // NeMo's unbiased per-feature normalization needs at least two frames.
        let pcm = input.count < 480 ? input + [Float](repeating: 0, count: 480 - input.count) : input
        let seconds = try SpeechCore.bucket(samples: pcm.count)
        let model = try models.model(load: loadEncoder)
        try check()
        let features = frontend.compute(pcm)
        let size = seconds * 100 + 1
        let mel = try MLMultiArray(shape: [1, 128, NSNumber(value: size)], dataType: .float32)
        let destination = mel.dataPointer.bindMemory(to: Float.self, capacity: mel.count)
        destination.initialize(repeating: 0, count: mel.count)
        features.features.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for channel in 0..<128 {
                (destination + channel * size).update(from: base + channel * features.frames, count: features.frames)
            }
        }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: features.valid)
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": mel, "mel_length": length]))
        guard let output = result.featureValue(for: "encoder")?.multiArrayValue,
              let valid = result.featureValue(for: "encoder_length")?.multiArrayValue else {
            throw TranscriptionError.invalidModelOutput
        }
        let frames = try EncoderFrames(output, validLength: valid[0].intValue)
        let projection = FloatBuffer(count: frames.count * NativeWeights.hidden)
        math.project(frames, length: frames.count, into: projection.pointer)
        return Projection(buffer: projection, frames: frames.count,
                          bytes: frames.count * NativeWeights.hidden * MemoryLayout<Float>.size)
    }

    func decode(_ projection: Projection, offset: Int, bias: BiasGraph?, check: () throws -> Void) throws -> [HeardWord] {
        let f = projection.buffer
        let hidden = NativeWeights.hidden, outputs = NativeWeights.outputs
        var h = [Float](repeating: 0, count: 2 * hidden), c = h
        var g = [Float](repeating: 0, count: hidden), z = g
        let logits = FloatBuffer(count: outputs)
        let tokens: [DecodedToken]
        if let bias {
            tokens = try SpeechCore.decode(length: projection.frames, bias: bias, predict: { token in
                math.predict(token, h: &h, c: &c, g: &g)
            }, joint: { frame in
                let decision = math.joint(f: f.pointer + frame * hidden, g: &g, z: &z, logits: logits.pointer)
                guard UnsafeBufferPointer(start: logits.pointer, count: outputs).allSatisfy(\.isFinite) else {
                    throw TranscriptionError.invalidModelOutput
                }
                return (UnsafePointer(logits.pointer), decision.1)
            }, check: check)
        } else {
            // No dictionary: exactly the unbiased decoding path.
            tokens = try SpeechCore.decode(length: projection.frames, predict: { token in
                math.predict(token, h: &h, c: &c, g: &g)
            }, joint: { frame in
                let decision = math.joint(f: f.pointer + frame * hidden, g: &g, z: &z, logits: logits.pointer)
                guard UnsafeBufferPointer(start: logits.pointer, count: outputs).allSatisfy(\.isFinite) else {
                    throw TranscriptionError.invalidModelOutput
                }
                return decision
            }, check: check)
        }
        return try SpeechCore.words(tokens, vocabulary: vocabulary, offset: offset)
    }
}
