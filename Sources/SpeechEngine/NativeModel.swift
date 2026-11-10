import Accelerate
import CoreML
import Foundation

// The model's native parts: the vDSP feature front end, the FP32 Accelerate TDT decoder and the files they are read
// from. Adapted from the native inference code of the upstream speech model work, MIT licensed (see the model's
// Software-LICENSE); no diagnostic capture or persistence.

/// Float storage that outlives the views onto it (encoder outputs, decoder buffers).
final class FloatBuffer {
    let pointer: UnsafeMutablePointer<Float>
    let count: Int

    init(count: Int) {
        self.count = count
        pointer = .allocate(capacity: max(count, 1))
        pointer.initialize(repeating: 0, count: max(count, 1))
    }

    convenience init(_ values: [Float]) {
        self.init(count: values.count)
        values.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { pointer.update(from: base, count: values.count) }
        }
    }

    deinit { pointer.deallocate() }
}

/// A float32 blob and its JSON manifest (tensors with shapes and byte offsets, and the blob's SHA-256).
struct NativeBlob {
    let tensors: [String: (shape: [Int], values: [Float])]

    init(directory: URL, stem: String) throws(TranscriptionError) {
        guard let json = try? Data(contentsOf: directory.appendingPathComponent("\(stem).json")),
              let manifest = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let file = manifest["file"] as? String, !file.isEmpty, !file.contains("/"), file != "..",
              let sha = manifest["sha256"] as? String,
              let list = manifest["tensors"] as? [[String: Any]],
              let data = try? Data(contentsOf: directory.appendingPathComponent(file)),
              SpeechCore.sha256(data) == sha else {
            throw .invalidModelFile
        }
        var out: [String: (shape: [Int], values: [Float])] = [:]
        let parsed: Bool = data.withUnsafeBytes { raw in
            for tensor in list {
                guard let name = tensor["name"] as? String, let shape = tensor["shape"] as? [Int],
                      !shape.isEmpty, shape.allSatisfy({ $0 > 0 }),
                      let offset = tensor["offset"] as? Int, offset >= 0, offset % 4 == 0,
                      let bytes = tensor["bytes"] as? Int, bytes > 0, bytes % 4 == 0,
                      offset <= data.count, bytes <= data.count - offset else {
                    return false
                }
                var count = 1
                for dimension in shape {
                    let product = count.multipliedReportingOverflow(by: dimension)
                    guard !product.overflow else { return false }
                    count = product.partialValue
                }
                guard count == bytes / 4, out[name] == nil else { return false }
                out[name] = (shape, stride(from: offset, to: offset + bytes, by: 4).map {
                    raw.loadUnaligned(fromByteOffset: $0, as: Float.self)
                })
            }
            return true
        }
        guard parsed else { throw .invalidModelFile }
        tensors = out
    }

    func tensor(_ name: String, _ shape: [Int]) throws(TranscriptionError) -> [Float] {
        guard let tensor = tensors[name], tensor.shape == shape else { throw .invalidModelFile }
        return tensor.values
    }
}

/// NeMo's FilterbankFeatures at inference on the CPU with Accelerate: dither off; pre-emphasis 0.97 within the valid
/// samples; centred STFT (n_fft 512, hop 160, zero padding of 256 each side, the stored symmetric Hann window of 400
/// centred in 512); |X|² as sqrt then square; the stored Slaney mel filterbank [128, 257]; log(x + 2⁻²⁴);
/// per-feature normalization over the valid frames M = N // 160 (mean, unbiased std + 1e-5); frames ≥ M set to 0.
/// Output [128, N // 160 + 1] feature-major. The window and filterbank are the model's stored values.
final class VDSPFrontEnd {
    static let nFFT = 512, hop = 160, winLength = 400, features = 128, bins = 257
    /// The stored window centred in n_fft (zeros outside).
    let window512: [Float]
    /// [128, 257]
    let fb: [Float]
    let preemph: Float = 0.97
    let logGuard = Float(pow(2.0, -24.0))
    let normConstant: Float = 1e-5
    let dft: vDSP_DFT_Setup
    let dftScale: Float

    convenience init(constantsDirectory: URL) throws(TranscriptionError) {
        let blob = try NativeBlob(directory: constantsDirectory, stem: "frontend")
        try self.init(window: try blob.tensor("window", [Self.winLength]), fb: try blob.tensor("fb", [Self.features, Self.bins]))
    }

    init(window: [Float], fb: [Float]) throws(TranscriptionError) {
        guard window.count == Self.winLength, fb.count == Self.features * Self.bins else { throw .invalidModelFile }
        self.fb = fb
        var w = [Float](repeating: 0, count: Self.nFFT)
        let offset = (Self.nFFT - Self.winLength) / 2
        for i in 0..<Self.winLength { w[offset + i] = window[i] }
        window512 = w
        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Self.nFFT), .FORWARD) else {
            throw .invalidModelFile
        }
        dft = setup
        // Calibrate vDSP's packed real-DFT scaling on a unit impulse (true DFT = 1 in every bin).
        var re = [Float](repeating: 0, count: Self.nFFT / 2), im = re, outR = re, outI = re
        re[0] = 1
        vDSP_DFT_Execute(setup, &re, &im, &outR, &outI)
        dftScale = 1 / outR[1]
    }

    deinit { vDSP_DFT_DestroySetup(dft) }

    /// Real DFT of 512 samples → re[257], im[257] (true DFT values; vDSP packs DC and Nyquist into element 0).
    func dft512(_ x: UnsafePointer<Float>, re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        let half = Self.nFFT / 2
        var even = [Float](repeating: 0, count: half), odd = even, outR = even, outI = even
        for k in 0..<half { even[k] = x[2 * k]; odd[k] = x[2 * k + 1] }
        vDSP_DFT_Execute(dft, &even, &odd, &outR, &outI)
        re[0] = outR[0] * dftScale; im[0] = 0
        re[half] = outI[0] * dftScale; im[half] = 0
        for k in 1..<half { re[k] = outR[k] * dftScale; im[k] = outI[k] * dftScale }
    }

    /// Features [128, T] (T = N // 160 + 1) and the valid frame count M = N // 160.
    func compute(_ pcm: [Float]) -> (features: [Float], frames: Int, valid: Int) {
        let n = pcm.count, nFFT = Self.nFFT, pad = nFFT / 2
        let valid = n / Self.hop, frames = n / Self.hop + 1
        // Pre-emphasis within the valid samples, then zero padding of n_fft / 2 on both sides.
        var padded = [Float](repeating: 0, count: n + 2 * pad)
        if n > 0 {
            padded[pad] = pcm[0]
            for i in 1..<n { padded[pad + i] = pcm[i] - preemph * pcm[i - 1] }
        }
        var power = [Float](repeating: 0, count: Self.bins * frames)   // [257, T]
        var frame = [Float](repeating: 0, count: nFFT)
        var re = [Float](repeating: 0, count: Self.bins), im = re
        padded.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            for f in 0..<frames {
                vDSP_vmul(base + f * Self.hop, 1, window512, 1, &frame, 1, vDSP_Length(nFFT))
                frame.withUnsafeBufferPointer { fr in
                    if let start = fr.baseAddress { dft512(start, re: &re, im: &im) }
                }
                for k in 0..<Self.bins {
                    let mag = (re[k] * re[k] + im[k] * im[k]).squareRoot()
                    power[k * frames + f] = mag * mag
                }
            }
        }
        var mel = [Float](repeating: 0, count: Self.features * frames)   // [128, T] = fb [128, 257] × power [257, T]
        vDSP_mmul(fb, 1, power, 1, &mel, 1, vDSP_Length(Self.features), vDSP_Length(frames), vDSP_Length(Self.bins))
        for i in 0..<mel.count { mel[i] = log(mel[i] + logGuard) }
        for c in 0..<Self.features {
            let row = c * frames
            var sum = 0.0
            for f in 0..<valid { sum += Double(mel[row + f]) }
            let mean = Float(sum / Double(valid))
            var sq = 0.0
            for f in 0..<valid { let d = Double(mel[row + f] - mean); sq += d * d }
            var std = Float((sq / Double(valid - 1)).squareRoot())
            if std.isNaN { std = 0 }
            std += normConstant
            for f in 0..<frames { mel[row + f] = f < valid ? (mel[row + f] - mean) / std : 0 }
        }
        return (mel, frames, valid)
    }
}

/// The decoder and joint weights (`decoder_joint.json` and its blob), checked against their expected shapes.
final class NativeWeights {
    static let hidden = 640, dModel = 1024, outputs = 1030, vocabPlusBlank = 1025
    let embed, wih0, whh0, bias0, w1cat, bias1, encW, encB, predW, predB, outW, outB: [Float]
    /// W_encᵀ [1024, 640], so the projection is one plain matrix product.
    let encWT: [Float]

    convenience init(directory: URL) throws(TranscriptionError) {
        let blob = try NativeBlob(directory: directory, stem: "decoder_joint")
        try self.init(tensors: blob.tensors.mapValues { $0.values })
    }

    /// From NeMo-named tensors, sizes checked.
    init(tensors: [String: [Float]]) throws(TranscriptionError) {
        func tensor(_ name: String, _ shape: [Int]) throws(TranscriptionError) -> [Float] {
            guard let values = tensors[name], values.count == shape.reduce(1, *) else { throw .invalidModelFile }
            return values
        }
        let h = Self.hidden, g = 4 * h
        let p = "decoder.prediction."
        embed = try tensor(p + "embed.weight", [Self.vocabPlusBlank, h])
        wih0 = try tensor(p + "dec_rnn.lstm.weight_ih_l0", [g, h])
        whh0 = try tensor(p + "dec_rnn.lstm.weight_hh_l0", [g, h])
        let bih0 = try tensor(p + "dec_rnn.lstm.bias_ih_l0", [g]), bhh0 = try tensor(p + "dec_rnn.lstm.bias_hh_l0", [g])
        let wih1 = try tensor(p + "dec_rnn.lstm.weight_ih_l1", [g, h])
        let whh1 = try tensor(p + "dec_rnn.lstm.weight_hh_l1", [g, h])
        let bih1 = try tensor(p + "dec_rnn.lstm.bias_ih_l1", [g]), bhh1 = try tensor(p + "dec_rnn.lstm.bias_hh_l1", [g])
        bias0 = zip(bih0, bhh0).map { $0 + $1 }
        bias1 = zip(bih1, bhh1).map { $0 + $1 }
        var cat = [Float](repeating: 0, count: g * 2 * h)  // [W_ih1 | W_hh1], [2560, 1280]
        for r in 0..<g {
            for c in 0..<h { cat[r * 2 * h + c] = wih1[r * h + c]; cat[r * 2 * h + h + c] = whh1[r * h + c] }
        }
        w1cat = cat
        encW = try tensor("joint.enc.weight", [h, Self.dModel]); encB = try tensor("joint.enc.bias", [h])
        encWT = Self.transpose(encW, rows: h, columns: Self.dModel)
        predW = try tensor("joint.pred.weight", [h, h]); predB = try tensor("joint.pred.bias", [h])
        outW = try tensor("joint.joint_net.2.weight", [Self.outputs, h])
        outB = try tensor("joint.joint_net.2.bias", [Self.outputs])
        // The blank embedding row is the start symbol, and must be zero.
        guard embed[(Self.vocabPlusBlank - 1) * h..<Self.vocabPlusBlank * h].allSatisfy({ $0 == 0 }) else {
            throw .invalidModelFile
        }
    }

    /// `matrix` [rows, columns] as [columns, rows].
    static func transpose(_ matrix: [Float], rows: Int, columns: Int) -> [Float] {
        var result = [Float](repeating: 0, count: matrix.count)
        vDSP_mtrans(matrix, 1, &result, 1, vDSP_Length(columns), vDSP_Length(rows))
        return result
    }
}

/// C [m, n] = A [m, p] × B [p, n], all row-major and contiguous.
@inline(__always)
func multiply(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, into c: UnsafeMutablePointer<Float>,
              m: Int, n: Int, p: Int) {
    vDSP_mmul(a, 1, b, 1, c, 1, vDSP_Length(m), vDSP_Length(n), vDSP_Length(p))
}

/// The decoder's math: the 2-layer LSTM step (PyTorch gate order i, f, g, o), the prediction projection and the
/// joint. Holds scratch buffers, so it is used from one isolation domain only.
final class NativeMath {
    let w: NativeWeights
    let h = NativeWeights.hidden
    /// Layer-0 input contribution per token: embed[token] W_ih0ᵀ + b_ih0 + b_hh0, [1025, 2560] (one sgemm at load).
    let table0: [Float]
    var gates = [Float](repeating: 0, count: 2560)
    var xcat = [Float](repeating: 0, count: 1280)
    /// A matrix-vector product before it is added in.
    var product = [Float](repeating: 0, count: 2560)
    /// Encoder frames copied time-major and contiguous when Core ML lays them out otherwise.
    private var frameScratch: [Float] = []

    init(_ w: NativeWeights) {
        self.w = w
        let g = 4 * NativeWeights.hidden, v = NativeWeights.vocabPlusBlank, h = NativeWeights.hidden
        var t = [Float](repeating: 0, count: v * g)
        let wih0T = NativeWeights.transpose(w.wih0, rows: g, columns: h)
        multiply(w.embed, wih0T, into: &t, m: v, n: g, p: h)
        for row in 0..<v {
            t.withUnsafeMutableBufferPointer { table in
                guard let base = table.baseAddress else { return }
                vDSP_vadd(base + row * g, 1, w.bias0, 1, base + row * g, 1, vDSP_Length(g))
            }
        }
        table0 = t
    }

    @inline(__always) static func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

    /// One LSTM cell update in place: h, c [640] with gates [2560] (already holding the input and bias part).
    func cell(_ gates: UnsafeMutablePointer<Float>, h hidden: UnsafeMutablePointer<Float>, c: UnsafeMutablePointer<Float>) {
        for k in 0..<h {
            let i = Self.sigmoid(gates[k]), f = Self.sigmoid(gates[h + k])
            let g = tanh(gates[2 * h + k]), o = Self.sigmoid(gates[3 * h + k])
            let cn = f * c[k] + i * g
            c[k] = cn
            hidden[k] = o * tanh(cn)
        }
    }

    /// The prediction network on `token` from state (h, c) [2, 640] each, updated in place; writes the projected
    /// output g = W_pred h_top + b_pred [640].
    func predict(_ token: Int, h hidden: UnsafeMutablePointer<Float>, c: UnsafeMutablePointer<Float>,
                 g output: UnsafeMutablePointer<Float>) {
        let g = 4 * h
        gates.withUnsafeMutableBufferPointer { gp in
            product.withUnsafeMutableBufferPointer { pp in
                guard let gates = gp.baseAddress, let product = pp.baseAddress else { return }
                // Layer 0: gates = table0[token] + W_hh0 h0.
                multiply(w.whh0, hidden, into: product, m: g, n: 1, p: h)
                table0.withUnsafeBufferPointer { table in
                    if let base = table.baseAddress { vDSP_vadd(base + token * g, 1, product, 1, gates, 1, vDSP_Length(g)) }
                }
                cell(gates, h: hidden, c: c)
                // Layer 1: gates = [W_ih1 | W_hh1] [h0'; h1] + b_ih1 + b_hh1.
                xcat.withUnsafeMutableBufferPointer { xp in
                    guard let x = xp.baseAddress else { return }
                    x.update(from: hidden, count: h)
                    (x + h).update(from: hidden + h, count: h)
                    multiply(w.w1cat, x, into: product, m: g, n: 1, p: 2 * h)
                }
                vDSP_vadd(w.bias1, 1, product, 1, gates, 1, vDSP_Length(g))
                cell(gates, h: hidden + h, c: c + h)
                // g = W_pred h_top + b_pred.
                multiply(w.predW, hidden + h, into: product, m: h, n: 1, p: h)
                vDSP_vadd(w.predB, 1, product, 1, output, 1, vDSP_Length(h))
            }
        }
    }

    /// The encoder-side joint projection of frames 0..<length: f [length, 640] = E W_encᵀ + b_enc (one sgemm).
    func project(_ frames: EncoderFrames, length: Int, into f: UnsafeMutablePointer<Float>) {
        let d = NativeWeights.dModel
        let contiguous = frames.hiddenStride == 1 && frames.timeStride == d
        if !contiguous {
            frameScratch = [Float](repeating: 0, count: length * d)
            frameScratch.withUnsafeMutableBufferPointer { scratch in
                guard let base = scratch.baseAddress else { return }
                for t in 0..<length {
                    gather(frames.base + t * frames.timeStride, stride: frames.hiddenStride, into: base + t * d,
                                  count: d)
                }
            }
        }
        let multiplyFrames = { (e: UnsafePointer<Float>) in multiply(e, self.w.encWT, into: f, m: length, n: self.h, p: d) }
        if contiguous {
            multiplyFrames(frames.base)
        } else {
            frameScratch.withUnsafeBufferPointer { scratch in
                if let base = scratch.baseAddress { multiplyFrames(base) }
            }
        }
        for t in 0..<length { vDSP_vadd(f + t * h, 1, w.encB, 1, f + t * h, 1, vDSP_Length(h)) }
    }

    /// Copies `count` floats `stride` apart into consecutive memory.
    private func gather(_ source: UnsafePointer<Float>, stride: Int, into destination: UnsafeMutablePointer<Float>,
                               count: Int) {
        for k in 0..<count { destination[k] = source[k * stride] }
    }

    /// Joint logits [1030] = W_out relu(f_t + g) + b_out; returns (argmax token over 1025, argmax duration bin).
    func joint(f: UnsafePointer<Float>, g: UnsafePointer<Float>, z: UnsafeMutablePointer<Float>,
               logits: UnsafeMutablePointer<Float>) -> (Int, Int) {
        vDSP_vadd(f, 1, g, 1, z, 1, vDSP_Length(h))
        var zero: Float = 0
        vDSP_vthr(z, 1, &zero, z, 1, vDSP_Length(h))
        multiply(w.outW, z, into: logits, m: NativeWeights.outputs, n: 1, p: h)
        vDSP_vadd(w.outB, 1, logits, 1, logits, 1, vDSP_Length(NativeWeights.outputs))
        return (argmax(logits, 1025), argmax(logits + 1025, 5))
    }

    /// The first maximum, as torch.max picks it.
    @inline(__always) func argmax(_ p: UnsafePointer<Float>, _ n: Int) -> Int {
        var best = 0
        for i in 1..<n where p[i] > p[best] { best = i }
        return best
    }
}

/// A stride-aware view of encoder frames: the Core ML output [1, 1024, T] or [1, T, 1024].
struct EncoderFrames {
    let count: Int
    let hiddenStride: Int
    let timeStride: Int
    let base: UnsafeMutablePointer<Float>
    /// Keeps the memory `base` points into alive.
    let owner: AnyObject

    init(_ output: MLMultiArray, validLength: Int) throws(TranscriptionError) {
        let shape = output.shape.map(\.intValue), strides = output.strides.map(\.intValue)
        guard shape.count == 3, shape[0] == 1, shape[1] == 1024 || shape[2] == 1024, output.dataType == .float32 else {
            throw .invalidModelOutput
        }
        let hiddenAxis = shape[1] == 1024 ? 1 : 2
        let timeAxis = 3 - hiddenAxis
        hiddenStride = strides[hiddenAxis]
        timeStride = strides[timeAxis]
        count = min(validLength, shape[timeAxis])
        guard count > 0, hiddenStride > 0, timeStride > 0 else { throw .invalidModelOutput }
        owner = output
        base = output.dataPointer.bindMemory(to: Float.self, capacity: output.count)
    }
}
