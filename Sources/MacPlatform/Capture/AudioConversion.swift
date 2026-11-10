@preconcurrency import AVFoundation
import CoreMedia
import DictationCore

/// Converts captured audio, in whatever PCM format the device delivers, to 16 kHz mono `Float`
/// (`AudioFormat.sampleRate`). It keeps the sample-rate converter's state between buffers, rebuilds it when the
/// input format changes (after flushing the old one's tail), and flushes the tail when the capture stops.
///
/// Not thread-safe: the capture that owns it serializes every call.
final class AudioConversion {
    enum Failure: Error, Equatable {
        /// The input format cannot be converted.
        case unsupportedFormat
        case conversionFailed
    }

    // A literal format AVFoundation always accepts.
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioFormat.sampleRate, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?

    /// Converts one buffer. With a new input format, the samples still inside the previous converter come first.
    func convert(_ buffer: AVAudioPCMBuffer) throws(Failure) -> [Float] {
        var samples: [Float] = []
        if let converter, converter.inputFormat != buffer.format {
            samples = try flush()
        }
        if converter == nil {
            guard let made = AVAudioConverter(from: buffer.format, to: Self.outputFormat) else {
                throw .unsupportedFormat
            }
            // Average the channels rather than keep only the first: a stereo microphone, or a headset that puts
            // the voice on one side, still comes through.
            made.downmix = true
            converter = made
        }
        samples += try run(buffer)
        return samples
    }

    /// Ends the input and returns what the converter still holds. The next buffer starts a fresh converter.
    func flush() throws(Failure) -> [Float] {
        guard converter != nil else { return [] }
        defer { converter = nil }
        return try run(nil)
    }

    private func run(_ input: AVAudioPCMBuffer?) throws(Failure) -> [Float] {
        guard let converter else { return [] }
        let feed = Feed(input)
        let ratio = Self.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input?.frameLength ?? 0) * ratio) + 1_024
        var samples: [Float] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else {
                throw .conversionFailed
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in feed.next(status) }
            if status == .error { throw .conversionFailed }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status != .haveData { return samples }
        }
    }

    /// Hands the converter one buffer, then says that nothing more is there for now, or, when flushing, that the
    /// input has ended.
    private final class Feed: @unchecked Sendable {
        // Safe: used only inside the synchronous `convert` call that created it, on the caller's thread.
        private var buffer: AVAudioPCMBuffer?
        private let ending: Bool

        init(_ buffer: AVAudioPCMBuffer?) {
            self.buffer = buffer
            ending = buffer == nil
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if let buffer {
                self.buffer = nil
                status.pointee = .haveData
                return buffer
            }
            status.pointee = ending ? .endOfStream : .noDataNow
            return nil
        }
    }
}

extension AVAudioPCMBuffer {
    /// Copies the audio out of a capture output's sample buffer, in the sample buffer's own format. Nil if it is
    /// not linear PCM or cannot be copied.
    static func copying(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaSubType(description) == kAudioFormatLinearPCM
        else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
