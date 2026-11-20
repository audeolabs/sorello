#if SORELLO_KEYBOARD_DICTATION
import Foundation

/// Converts mono audio at the capture's rate to the engine's 16 kHz, a chunk at a time (ARCHITECTURE.md, "In-keyboard
/// dictation (experiment)", Capture). A windowed-sinc low-pass interpolator: it filters out what 16 kHz cannot hold
/// before taking each output sample, so speech keeps its sound and nothing above 8 kHz folds back into it. Chunked
/// input gives the same output as the whole at once; `flush` gives the tail.
struct StreamingResampler: Sendable {
    static let outputRate = 16_000.0
    /// Kernel half-width in zero crossings, and the kernel's phases per input sample.
    private static let zeroCrossings = 8
    private static let phases = 256

    let inputRate: Double
    /// Input samples per output sample.
    private let step: Double
    /// Taps on each side of the output's position, in input samples.
    private let halfWidth: Int
    /// `phases + 1` rows of `2 * halfWidth` taps: row p holds the kernel for an output p/phases of a sample past an
    /// input sample, taps for inputs `-halfWidth + 1 ... halfWidth` around it, each row summing to 1.
    private let kernel: [Float]
    /// Input not yet needed by no output: `history[0]` is input sample `historyStart`.
    private var history: [Float] = []
    private var historyStart = 0
    private var inputCount = 0
    private var produced = 0

    init(inputRate: Double) {
        precondition(inputRate.isFinite && inputRate > 0)
        self.inputRate = inputRate
        step = inputRate / Self.outputRate
        // The cutoff, in cycles per input sample: just below the lower of the two Nyquist frequencies.
        let cutoff = 0.45 * min(1, Self.outputRate / inputRate)
        let halfWidth = Int((Double(Self.zeroCrossings) / (2 * cutoff)).rounded(.up))
        self.halfWidth = halfWidth
        var kernel = [Float](repeating: 0, count: (Self.phases + 1) * 2 * halfWidth)
        for phase in 0 ... Self.phases {
            let fraction = Double(phase) / Double(Self.phases)
            var row = [Double](repeating: 0, count: 2 * halfWidth)
            for tap in 0 ..< 2 * halfWidth {
                // The input's offset from the output's position.
                let distance = Double(tap - halfWidth + 1) - fraction
                let x = 2 * cutoff * distance
                let sinc = x == 0 ? 1 : sin(.pi * x) / (.pi * x)
                let windowPosition = distance / Double(halfWidth)
                let window = abs(windowPosition) >= 1 ? 0
                    : 0.42 + 0.5 * cos(.pi * windowPosition) + 0.08 * cos(2 * .pi * windowPosition)
                row[tap] = sinc * window
            }
            let sum = row.reduce(0, +)
            for tap in 0 ..< 2 * halfWidth { kernel[phase * 2 * halfWidth + tap] = Float(row[tap] / sum) }
        }
        self.kernel = kernel
    }

    /// The output samples `input` completes; the rest wait for more input or `flush`.
    mutating func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        if inputRate == Self.outputRate {
            inputCount += input.count
            produced += input.count
            return input
        }
        history.append(contentsOf: input)
        inputCount += input.count
        return produce(upTo: Int((Double(inputCount) / step).rounded(.down)), padded: false)
    }

    /// The tail: every output sample the input so far makes, `inputCount × 16 kHz / rate` of them in all.
    mutating func flush() -> [Float] {
        guard inputRate != Self.outputRate else { return [] }
        return produce(upTo: Int((Double(inputCount) / step).rounded(.down)), padded: true)
    }

    /// Outputs until `total` have been made, each once the input it needs has arrived (or, `padded`, as if silence
    /// followed). Drops the history no later output needs.
    private mutating func produce(upTo total: Int, padded: Bool) -> [Float] {
        var output: [Float] = []
        while produced < total {
            let position = Double(produced) * step
            let base = Int(position.rounded(.down))
            guard padded || base + halfWidth < inputCount else { break }
            var phase = Int(((position - Double(base)) * Double(Self.phases)).rounded())
            var center = base
            if phase == Self.phases { phase = 0; center += 1 }
            let row = phase * 2 * halfWidth
            var sum: Float = 0
            for tap in 0 ..< 2 * halfWidth {
                let index = center - halfWidth + 1 + tap - historyStart
                guard index >= 0, index < history.count else { continue }
                sum += history[index] * kernel[row + tap]
            }
            output.append(sum)
            produced += 1
        }
        let keepFrom = Int((Double(produced) * step).rounded(.down)) - halfWidth
        if keepFrom > historyStart {
            let drop = min(keepFrom - historyStart, history.count)
            history.removeFirst(drop)
            historyStart += drop
        }
        return output
    }
}

/// What the capture page posts, as Swift accepts it (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Capture).
/// Only well-formed chunks of at most `maxChunkDuration`, in order, at one rate, are audio; anything else is malformed.
struct CaptureMessageReader: Sendable {
    enum Message: Equatable, Sendable {
        /// One chunk, mono, at `rate`, and the microphone the page believed it recorded from, if it said.
        case audio(samples: [Float], rate: Double, input: KeyboardDictationRecord.CaptureInput? = nil)
        /// The page could not capture (getUserMedia refused or failed).
        case failed
        /// A track ended by itself.
        case ended
        case malformed
    }

    static let rateRange: ClosedRange<Double> = 8_000 ... 192_000
    private var nextSequence = 0
    private(set) var rate: Double?

    /// Reads one message body (`WKScriptMessage.body`: a dictionary of strings and numbers).
    mutating func read(_ body: Any) -> Message {
        guard let message = body as? [String: Any], let kind = message["kind"] as? String else { return .malformed }
        switch kind {
        case "failed": return .failed
        case "ended": return .ended
        case "audio": break
        default: return .malformed
        }
        guard let sequence = Self.integer(message["seq"]), sequence == nextSequence,
              let rate = Self.number(message["rate"]), rate == rate.rounded(), Self.rateRange.contains(rate),
              self.rate == nil || self.rate == rate, let encoded = message["pcm"] as? String
        else { return .malformed }
        var input: KeyboardDictationRecord.CaptureInput?
        if let mic = message["mic"] {
            guard let word = mic as? String, let named = KeyboardDictationRecord.CaptureInput(rawValue: word) else {
                return .malformed
            }
            input = named
        }
        // At most `maxChunkDuration` of samples, judged on the text before anything is decoded.
        let maxBytes = 2 * Int((rate * KeyboardDictationTiming.maxChunkDuration).rounded(.down))
        guard encoded.utf8.count <= (maxBytes + 2) / 3 * 4, let data = Data(base64Encoded: encoded),
              !data.isEmpty, data.count % 2 == 0, data.count <= maxBytes
        else { return .malformed }
        nextSequence += 1
        self.rate = rate
        var samples = [Float](repeating: 0, count: data.count / 2)
        data.withUnsafeBytes { bytes in
            for index in samples.indices {
                let value = Int16(bitPattern: UInt16(bytes[2 * index]) | UInt16(bytes[2 * index + 1]) << 8)
                samples[index] = Float(value) / 32_768
            }
        }
        return .audio(samples: samples, rate: rate, input: input)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let double = number(value), double == double.rounded(), abs(double) < 1e9 else { return nil }
        return Int(double)
    }
}

/// One in-keyboard dictation's audio at 16 kHz, in memory only, at most `maxDictationDuration` of it
/// (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Capture and Transcription). Chunks are converted as they are
/// accepted; the seal converts the tail, once, and after it nothing more is kept. The stream takes what it has not had
/// yet: all of it, once, the first time, then each converted chunk.
struct KeyboardRecording: Sendable {
    static let maxSamples = Int(DictationProtocol.maxDictationDuration * StreamingResampler.outputRate)

    private var resampler: StreamingResampler?
    private(set) var samples: [Float] = []
    private(set) var isSealed = false
    /// Samples already handed to the stream.
    private var streamed = 0

    /// The capture's rate, once the first chunk set it.
    var captureRate: Double? { resampler?.inputRate }
    var seconds: Double { Double(samples.count) / StreamingResampler.outputRate }

    /// Converts and keeps a chunk at `rate`. False, keeping nothing, when sealed or at a rate other than the first.
    @discardableResult
    mutating func append(_ chunk: [Float], rate: Double) -> Bool {
        guard !isSealed else { return false }
        if resampler == nil { resampler = StreamingResampler(inputRate: rate) }
        guard var resampler, resampler.inputRate == rate else { return false }
        keep(resampler.process(chunk))
        self.resampler = resampler
        return true
    }

    /// Converts the tail; nothing is kept after it.
    mutating func seal() {
        guard !isSealed else { return }
        if var resampler {
            keep(resampler.flush())
            self.resampler = resampler
        }
        isSealed = true
    }

    /// What the stream has not had yet.
    mutating func takeForStream() -> [Float] {
        guard streamed < samples.count else { return [] }
        defer { streamed = samples.count }
        return Array(samples[streamed...])
    }

    private mutating func keep(_ converted: [Float]) {
        let room = Self.maxSamples - samples.count
        guard room > 0 else { return }
        samples.append(contentsOf: converted.prefix(room))
    }
}
#endif
