import AVFoundation
import Foundation

/// Reads an audio file as the model hears it: mono 32-bit float at 16 kHz, in bounded pieces. `sorello-transcribe`
/// and tests use it; the app's own recordings arrive as samples, and a file to transcribe is read by the engine
/// through `AudioFileSource`, the same reader.
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
        do {
            let source = try AudioFileSource(contentsOf: url)
            while true {
                try check()
                guard let piece = try source.next() else { return }
                try consume(piece)
            }
        } catch {
            throw ReadError()
        }
    }
}

/// Why a file could not be read as audio (ARCHITECTURE.md, section 5, "Transcribing a file"). Content-free: neither
/// case carries the file's name or anything it holds.
public enum AudioFileFailure: Error, Sendable, Equatable {
    /// The file is not there, is a directory, or may not be read.
    case cannotOpen
    /// The file is there, but `AVAudioFile` cannot read it: a format it does not read, no soundtrack, or damage part
    /// way through.
    case unreadable
}

/// Where the engine pulls a file's audio from, one piece at a time, as the model hears it. The engine asks for the
/// next piece only when the last has gone into the chunker, so nothing piles up ahead of the model.
protocol AudioPieceSource: AnyObject {
    /// How long the audio is, in seconds, as the file says. For a compressed file this may be an estimate.
    var length: TimeInterval { get }
    /// How much of the audio has been read, in seconds of the file's own time.
    var position: TimeInterval { get }
    /// The next piece, at most `AudioFileSource.pieceSamples` samples of 16 kHz mono, or nil at the end.
    func next() throws(AudioFileFailure) -> [Float]?
}

/// Opens a source to read, on the engine's executor.
typealias AudioSourceOpener = @Sendable () throws(AudioFileFailure) -> any AudioPieceSource

/// One audio file, opened once and read as the model hears it: mono 32-bit float at 16 kHz, a piece of at most 8192
/// samples at a time. `AVAudioFile` reads the file's first audio track, which is how a video's soundtrack is read;
/// Sorello adds no decoder of its own. The end of the file is checked before more is asked for, because AIFF can
/// throw when read past its end.
///
/// Not safe to share between threads: one reader uses it at a time, as the engine does on its executor.
public final class AudioFileSource: AudioPieceSource {
    /// The most samples one piece holds.
    public static let pieceSamples = 8192

    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var ended = false

    /// How long the audio is, in seconds, as the file says. For a compressed file this may be an estimate, and the
    /// audio read may come out a little longer or shorter.
    public let length: TimeInterval

    /// Opens `url` for reading. Throws `cannotOpen` when it is not there, is a directory or may not be read, and
    /// `unreadable` when it opens but holds no audio `AVAudioFile` can read.
    public init(contentsOf url: URL) throws(AudioFileFailure) {
        try Self.checkOpenable(url)
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw .unreadable }
        guard file.processingFormat.channelCount > 0, file.processingFormat.sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(Self.pieceSamples)),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.pieceSamples))
        else {
            throw .unreadable
        }
        self.file = file
        self.converter = converter
        self.input = input
        self.output = output
        length = Double(file.length) / file.processingFormat.sampleRate
    }

    /// How much of the audio has been read, in seconds of the file's own time.
    public var position: TimeInterval { Double(file.framePosition) / file.processingFormat.sampleRate }

    /// The next piece, or nil once the whole file has been read. Throws `unreadable` when the file turns out to be
    /// damaged part way through.
    public func next() throws(AudioFileFailure) -> [Float]? {
        guard !ended else { return nil }
        var readFailed = false
        var conversionError: NSError?
        let file = self.file, input = self.input
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
        guard !readFailed, conversionError == nil, status != .error else { throw .unreadable }
        if status == .inputRanDry && output.frameLength == 0 { throw .unreadable }
        ended = status == .endOfStream
        guard let samples = output.floatChannelData?[0], output.frameLength > 0 else { return ended ? nil : [] }
        return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }

    /// Tells a file that cannot be opened from one that opens but cannot be read: it must exist, not be a
    /// directory, and open for reading. The probe never blocks, even on a pipe with no writer.
    private static func checkOpenable(_ url: URL) throws(AudioFileFailure) {
        guard url.isFileURL else { throw .cannotOpen }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw .cannotOpen }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw .cannotOpen }
        switch status.st_mode & S_IFMT {
        case S_IFDIR: throw .cannotOpen
        case S_IFREG: return
        // A pipe, a device or a socket opens, but is not a file AVAudioFile can read.
        default: throw .unreadable
        }
    }
}
