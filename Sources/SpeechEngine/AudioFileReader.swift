import AVFoundation
import Foundation

/// Reads an audio file as the model hears it: mono 32-bit float at 16 kHz, in bounded pieces. It checks for the end
/// of the file before asking for more, because AIFF can throw when read past its end. `sorello-transcribe` and tests
/// use it; the app's own recordings arrive as samples.
public enum AudioFileReader {
    /// The file could not be opened or decoded. Content-free: it never names the file.
    public struct ReadError: Error, Equatable, Sendable {}

    /// Every sample of `url`, resampled to 16 kHz mono.
    public static func samples(contentsOf url: URL) throws(ReadError) -> [Float] {
        var samples: [Float] = []
        try read(url, check: {}) { samples += $0 }
        return samples
    }

    /// Hands `consume` the file in pieces of at most 8192 samples, in order. `check` runs before each piece and may
    /// throw to stop.
    static func read(_ url: URL, check: () throws -> Void, consume: ([Float]) throws -> Void) throws(ReadError) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw ReadError() }
        guard file.processingFormat.channelCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw ReadError()
        }
        var ended = false
        while !ended {
            do { try check() } catch { throw ReadError() }
            var readFailed = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                guard file.framePosition < file.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    let remaining = AVAudioFrameCount(min(file.length - file.framePosition,
                                                          AVAudioFramePosition(input.frameCapacity)))
                    try file.read(into: input, frameCount: min(requested, remaining))
                    inputStatus.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                    return input.frameLength == 0 ? nil : input
                } catch {
                    readFailed = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            guard !readFailed, conversionError == nil, status != .error else { throw ReadError() }
            if let samples = output.floatChannelData?[0] {
                do { try consume(Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))) } catch {
                    throw ReadError()
                }
            }
            ended = status == .endOfStream
            if status == .inputRanDry && output.frameLength == 0 { throw ReadError() }
        }
    }
}
