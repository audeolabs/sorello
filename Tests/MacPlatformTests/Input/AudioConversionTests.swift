@preconcurrency import AVFoundation
import CoreMedia
@testable import MacPlatform
import Testing

/// Synthetic audio: a sine wave in any PCM format.
enum Tone {
    static func buffer(rate: Double, channels: AVAudioChannelCount = 1, frames: Int, frequency: Double = 440,
                       amplitude: Float = 0.5, startFrame: Int = 0,
                       format common: AVAudioCommonFormat = .pcmFormatFloat32,
                       interleaved: Bool = false) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: common, sampleRate: rate, channels: channels,
                                   interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let lists = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let stride = interleaved ? Int(channels) : 1
        for list in lists {
            let channelsHere = interleaved ? Int(channels) : 1
            for frame in 0..<frames {
                let value = amplitude * Float(sin(2 * .pi * frequency * Double(startFrame + frame) / rate))
                for channel in 0..<channelsHere {
                    let slot = frame * stride + channel
                    switch common {
                    case .pcmFormatInt16:
                        list.mData!.assumingMemoryBound(to: Int16.self)[slot] = Int16(value * Float(Int16.max))
                    default:
                        list.mData!.assumingMemoryBound(to: Float.self)[slot] = value
                    }
                }
            }
        }
        return buffer
    }

    /// Feeds `seconds` of tone in 10 ms buffers.
    static func buffers(rate: Double, channels: AVAudioChannelCount = 1, seconds: Double,
                        format: AVAudioCommonFormat = .pcmFormatFloat32,
                        interleaved: Bool = false) -> [AVAudioPCMBuffer] {
        let total = Int(rate * seconds)
        let step = Int(rate / 100)
        return stride(from: 0, to: total, by: step).map {
            buffer(rate: rate, channels: channels, frames: min(step, total - $0), startFrame: $0, format: format,
                   interleaved: interleaved)
        }
    }

    /// Upward zero crossings per second, which is the tone's frequency.
    static func frequency(of samples: [Float], rate: Double = 16_000) -> Double {
        let crossings = zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        return Double(crossings) / (Double(samples.count) / rate)
    }

    static func peak(of samples: [Float]) -> Float {
        samples.map(abs).max() ?? 0
    }
}

@Suite("Audio conversion")
struct AudioConversionTests {
    private func convertAll(_ buffers: [AVAudioPCMBuffer]) throws -> [Float] {
        let conversion = AudioConversion()
        var samples: [Float] = []
        for buffer in buffers { samples += try conversion.convert(buffer) }
        samples += try conversion.flush()
        return samples
    }

    @Test("48 kHz stereo becomes 16 kHz mono with the same tone and level")
    func stereo48k() throws {
        let samples = try convertAll(Tone.buffers(rate: 48_000, channels: 2, seconds: 1))
        #expect(abs(samples.count - 16_000) <= 2)
        #expect(abs(Tone.frequency(of: samples) - 440) < 3)
        #expect(abs(Tone.peak(of: samples) - 0.5) < 0.03)
    }

    @Test("44.1 kHz 16-bit interleaved becomes 16 kHz Float")
    func int16Interleaved() throws {
        let samples = try convertAll(Tone.buffers(rate: 44_100, channels: 2, seconds: 1, format: .pcmFormatInt16,
                                                  interleaved: true))
        #expect(abs(samples.count - 16_000) <= 2)
        #expect(abs(Tone.frequency(of: samples) - 440) < 3)
        #expect(abs(Tone.peak(of: samples) - 0.5) < 0.03)
    }

    @Test("The flush delivers the converter's tail, so nothing is lost at the end")
    func flushDeliversTail() throws {
        let conversion = AudioConversion()
        var before: [Float] = []
        for buffer in Tone.buffers(rate: 48_000, seconds: 0.5) { before += try conversion.convert(buffer) }
        let tail = try conversion.flush()
        #expect(!tail.isEmpty)
        #expect(abs(before.count + tail.count - 8_000) <= 2)
        #expect(try conversion.flush() == [], "a second flush has nothing")
    }

    @Test("A format change mid-capture rebuilds the converter and keeps the old one's tail")
    func formatChange() throws {
        let buffers = Tone.buffers(rate: 48_000, seconds: 0.5) + Tone.buffers(rate: 44_100, channels: 2, seconds: 0.5)
        let samples = try convertAll(buffers)
        #expect(abs(samples.count - 16_000) <= 4)
        #expect(abs(Tone.frequency(of: samples) - 440) < 5)
    }

    @Test("16 kHz mono Float passes through unchanged")
    func passThrough() throws {
        let buffer = Tone.buffer(rate: 16_000, frames: 1_600)
        let samples = try convertAll([buffer])
        let original = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 1_600))
        #expect(samples == original)
    }

    @Test("A capture output's sample buffer is copied out in its own format")
    func copiesSampleBuffer() throws {
        for source in [Tone.buffer(rate: 48_000, channels: 2, frames: 480, format: .pcmFormatInt16, interleaved: true),
                       Tone.buffer(rate: 16_000, frames: 160)] {
            var sampleBuffer: CMSampleBuffer?
            #expect(CMAudioSampleBufferCreateWithPacketDescriptions(
                allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                formatDescription: source.format.formatDescription, sampleCount: CMItemCount(source.frameLength),
                presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sampleBuffer) == noErr)
            let made = try #require(sampleBuffer)
            #expect(CMSampleBufferSetDataBufferFromAudioBufferList(
                made, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
                bufferList: source.audioBufferList) == noErr)
            let copy = try #require(AVAudioPCMBuffer.copying(made))
            #expect(copy.format == source.format)
            #expect(copy.frameLength == source.frameLength)
            let bytes = Int(source.audioBufferList.pointee.mBuffers.mDataByteSize)
            #expect(memcmp(copy.audioBufferList.pointee.mBuffers.mData, source.audioBufferList.pointee.mBuffers.mData,
                           bytes) == 0)
        }
    }
}
