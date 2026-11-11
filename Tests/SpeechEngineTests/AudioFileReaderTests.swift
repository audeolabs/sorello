import AVFoundation
import Foundation
import Testing
@testable import SpeechEngine

/// Reading audio files as the model hears them. Invented audio only: silence and seeded noise.
struct AudioFileReaderTests {
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Stereo AIFF at 22.05 kHz is resampled to 16 kHz mono through its end, in bounded pieces.
    @Test func syntheticAudioThroughEndOfFile() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.aiff")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 53258))
        buffer.frameLength = buffer.frameCapacity
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<2 { channels[channel].initialize(repeating: 0, count: Int(buffer.frameLength)) }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        try AVAudioFile(forWriting: url, settings: settings).write(from: buffer)

        var samples = 0, calls = 0
        try AudioFileReader.read(url, check: {}) { chunk in
            samples += chunk.count
            calls += 1
            #expect(chunk.count <= 8192, "The reader keeps bounded buffers")
            #expect(chunk.allSatisfy { $0.isFinite && $0 == 0 }, "Silence stays finite")
        }
        #expect(calls > 1, "The fixture must exercise multiple reads and the end of the file")
        #expect(abs(samples - Int(Double(buffer.frameLength) * 16000 / 22050)) <= 1, "Resampling keeps the whole recording")
        #expect(throws: AudioFileReader.ReadError.self) {
            try AudioFileReader.read(url, check: { throw CancellationError() }, consume: { _ in })
        }
        #expect(throws: AudioFileReader.ReadError.self) {
            try AudioFileReader.samples(contentsOf: directory.appendingPathComponent("missing.wav"))
        }
    }

    /// A 16 kHz mono 16-bit file, as `say` writes, reads back as its samples divided by 32768, including the extremes.
    @Test func sixteenBitFilesReadExactly() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        var written: [Float] = [], state: UInt32 = 1
        // The file is finished when it is released, at the end of this block.
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
            for count in [341, 1, 8192, 9000] {
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                buffer.frameLength = AVAudioFrameCount(count)
                let data = try #require(buffer.int16ChannelData)[0]
                for index in 0..<count {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    data[index] = Int16(truncatingIfNeeded: state >> 16)
                }
                if count == 341 { data[0] = .min; data[1] = .max }
                try file.write(from: buffer)
                written += (0..<count).map { Float(data[$0]) / 32768 }
            }
        }
        let read = try AudioFileReader.samples(contentsOf: url)
        #expect(read == written, "The samples read equal the samples written")
        #expect(Array(written.prefix(2)) == [-1, Float(32767) / 32768])
    }
}
