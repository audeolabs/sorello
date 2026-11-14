import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import SpeechEngine

/// The kinds of file a transcription reads (ARCHITECTURE.md, section 5, "Transcribing a file"), each made here from an
/// invented tone and read back as the model hears it, and the kinds it refuses. The Mac cannot write MP3, Ogg (Vorbis
/// or Opus), WebM or Matroska, so Opus is made here in CAF, and those files are checked by hand with ffmpeg's from
/// `say`.
struct AudioFormatTests {
    /// Two seconds of a 440 Hz tone, mono, at `rate`.
    static let rate = 44_100.0
    static let seconds = 2.0
    static func tone(rate: Double = rate) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1,
                                                interleaved: false))
        let count = AVAudioFrameCount(rate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let channel = try #require(buffer.floatChannelData)[0]
        for index in 0..<Int(count) { channel[index] = Float(0.25 * sin(2 * Double.pi * 440 * Double(index) / rate)) }
        return buffer
    }

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AudioFormatTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes the tone with `settings`, the file's type taken from the name's extension.
    private func write(_ name: String, in directory: URL, _ settings: [String: Any]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        // The file is finished when it is released, at the end of this block.
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            try file.write(from: try Self.tone(rate: file.processingFormat.sampleRate))
        }
        return url
    }

    /// The tone read back: about two seconds at 16 kHz, as loud as it was written, and a tone, not noise.
    private func expectTone(_ url: URL, lossless: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let source = try AudioFileSource(contentsOf: url)
        #expect(abs(source.length - Self.seconds) < 0.1, "Length \(source.length)", sourceLocation: sourceLocation)
        let samples = try AudioFileReader.samples(contentsOf: url)
        #expect(abs(Double(samples.count) - Self.seconds * 16_000) < (lossless ? 2 : 3_000),
                "\(samples.count) samples", sourceLocation: sourceLocation)
        let middle = samples.dropFirst(samples.count / 4).prefix(samples.count / 2)
        let rms = (middle.reduce(0) { $0 + Double($1) * Double($1) } / Double(middle.count)).squareRoot()
        #expect(abs(rms - 0.25 / 2.0.squareRoot()) < 0.02, "RMS \(rms)", sourceLocation: sourceLocation)
        // A 440 Hz tone crosses zero 880 times a second.
        let crossings = zip(middle, middle.dropFirst()).count { ($0 < 0) != ($1 < 0) }
        let expected = 880 * Double(middle.count) / 16_000
        #expect(abs(Double(crossings) - expected) < 5, "\(crossings) crossings, not \(expected)",
                sourceLocation: sourceLocation)
    }

    @Test func uncompressedAndLosslessFilesReadBack() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate,
                                  AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                                  AVLinearPCMIsNonInterleaved: false]
        try expectTone(try write("tone.wav", in: directory, pcm.merging([AVLinearPCMIsBigEndianKey: false]) { $1 }),
                       lossless: true)
        try expectTone(try write("tone.aiff", in: directory, pcm.merging([AVLinearPCMIsBigEndianKey: true]) { $1 }),
                       lossless: true)
        try expectTone(try write("tone.caf", in: directory, pcm.merging([AVLinearPCMIsBigEndianKey: false]) { $1 }),
                       lossless: true)
        let lossless: [String: Any] = [AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1]
        try expectTone(try write("tone.flac", in: directory, lossless.merging([AVFormatIDKey: kAudioFormatFLAC]) { $1 }),
                       lossless: true)
        try expectTone(try write("alac.m4a", in: directory,
                                 lossless.merging([AVFormatIDKey: kAudioFormatAppleLossless]) { $1 }), lossless: true)
    }

    @Test func compressedFilesReadBack() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try expectTone(try write("aac.m4a", in: directory, [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.rate,
                                                             AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]),
                       lossless: false)
        try expectTone(try write("opus.caf", in: directory, [AVFormatIDKey: kAudioFormatOpus, AVSampleRateKey: 48_000.0,
                                                              AVNumberOfChannelsKey: 1]), lossless: false)
    }

    /// A video's soundtrack is read, in an MP4 and in a QuickTime movie; a video without sound is refused.
    @Test func aVideosSoundtrackIsReadAndAVideoWithoutSoundIsRefused() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let silent = directory.appendingPathComponent("silent.mov")
        try await Self.writeVideo(to: silent)
        #expect(throws: AudioFileFailure.unreadable) { try AudioFileSource(contentsOf: silent) }

        let sound = try write("sound.m4a", in: directory, [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.rate,
                                                           AVNumberOfChannelsKey: 1])
        for (name, type) in [("movie.mp4", AVFileType.mp4), ("movie.mov", AVFileType.mov)] {
            let movie = directory.appendingPathComponent(name)
            try await Self.combine(video: silent, sound: sound, into: movie, as: type)
            try expectTone(movie, lossless: false)
        }
    }

    /// WebM and Matroska are refused, and so is a file that is not audio at all.
    @Test func otherFilesAreRefused() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The EBML header every WebM and Matroska file starts with, then its document type; nothing on the Mac can
        // write the rest.
        for (name, kind) in [("clip.webm", "webm"), ("clip.mkv", "matroska")] {
            let url = directory.appendingPathComponent(name)
            var header = Data([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x82, UInt8(0x80 | kind.utf8.count)])
            header.append(contentsOf: Array(kind.utf8))
            header.append(Data(count: 4096))
            try header.write(to: url)
            #expect(throws: AudioFileFailure.unreadable) { try AudioFileSource(contentsOf: url) }
        }
        let text = directory.appendingPathComponent("notes.txt")
        try Data("Invented words, not audio.\n".utf8).write(to: text)
        #expect(throws: AudioFileFailure.unreadable) { try AudioFileSource(contentsOf: text) }
        #expect(throws: AudioFileFailure.cannotOpen) { try AudioFileSource(contentsOf: directory) }
        #expect(throws: AudioFileFailure.cannotOpen) {
            try AudioFileSource(contentsOf: directory.appendingPathComponent("absent.wav"))
        }
    }

    // MARK: - Making videos

    /// One second of a grey 64 x 64 H.264 video, with no sound.
    static func writeVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var made: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &made)
            let pixels = try #require(made)
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                memset(base, 0x80, CVPixelBufferGetDataSize(pixels))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    /// `video`'s picture and `sound`'s soundtrack, copied as they are into one movie of `type`. The assets are kept
    /// until the export ends: their tracks do not keep them.
    static func combine(video: URL, sound: URL, into url: URL, as type: AVFileType) async throws {
        let pictureAsset = AVURLAsset(url: video), soundAsset = AVURLAsset(url: sound)
        let picture = try #require(try await pictureAsset.loadTracks(withMediaType: .video).first)
        let audio = try #require(try await soundAsset.loadTracks(withMediaType: .audio).first)
        let composition = AVMutableComposition()
        let pictureTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try pictureTrack?.insertTimeRange(try await picture.load(.timeRange), of: picture, at: .zero)
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        try audioTrack?.insertTimeRange(try await audio.load(.timeRange), of: audio, at: .zero)
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: url, as: type)
        withExtendedLifetime((pictureAsset, soundAsset)) {}
    }

}
