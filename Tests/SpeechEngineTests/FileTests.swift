import AVFoundation
import DictationCore
import DictionaryKit
import Foundation
import Synchronization
import Testing
@testable import SpeechEngine

/// A file's transcription through the engine (ARCHITECTURE.md, section 5, "Transcribing a file"), with the fake model
/// and audio invented on the fly: tones, which the model hears as one word a second, and digital silence.
struct FileTests {
    /// Seconds of a loud tone, or of silence.
    enum Segment {
        case tone(Double)
        case silence(Double)
        /// Quiet noise, 50 dB below full scale: never speech to the compactor, but heard by the fake model.
        case hum(Double)

        var samples: Int { Signals.s(seconds) }
        var seconds: Double {
            switch self {
            case .tone(let seconds), .silence(let seconds), .hum(let seconds): seconds
            }
        }
    }

    /// The sample at `index` of a signal made of `segments`, computed on its own so no test builds a long file.
    static func sample(_ index: Int, of segments: [Segment]) -> Float {
        var start = 0
        for segment in segments {
            if index < start + segment.samples {
                switch segment {
                case .tone: return Float(0.1 * 2.0.squareRoot() * sin(2 * Double.pi * 440 * Double(index) / 16_000))
                case .silence: return 0
                case .hum:
                    // A hash of the index, so any sample can be made on its own.
                    var mixed = UInt64(index) &* 0x9E37_79B9_7F4A_7C15
                    mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
                    mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
                    mixed ^= mixed >> 31
                    let uniform = Double(mixed >> 11) / Double(1 << 53) * 2 - 1
                    return Float(pow(10, -50.0 / 20) * 3.0.squareRoot() * uniform)
                }
            }
            start += segment.samples
        }
        return 0
    }

    static func samples(_ segments: [Segment]) -> [Float] {
        (0..<segments.reduce(0) { $0 + $1.samples }).map { sample($0, of: segments) }
    }

    /// What a source handed out, readable by the test after the source has gone to the engine.
    final class SourceLog: Sendable {
        private struct State {
            var handed = 0
            var mostAhead = 0
        }

        private let state = Mutex(State())
        var handed: Int { state.withLock { $0.handed } }
        /// The most samples ever handed out beyond the end of the last chunk the model had seen.
        var mostAhead: Int { state.withLock { $0.mostAhead } }

        func handedOut(_ total: Int, modelReached: Int) {
            state.withLock {
                $0.handed = total
                $0.mostAhead = max($0.mostAhead, total - modelReached)
            }
        }
    }

    /// Hands out a signal of `segments` a piece at a time, computing each piece when it is asked for. `failAt` makes
    /// it throw once that many samples have been handed out, as a file damaged part way through does.
    final class SignalSource: AudioPieceSource {
        let segments: [Segment]
        let total: Int
        let piece: Int
        let failAt: Int?
        let log: SourceLog
        let model: ModelLog
        let onPiece: (@Sendable (Int) -> Void)?
        /// How long each piece takes to read, as decoding a compressed file does.
        let pieceDelay: TimeInterval
        private var handed = 0

        init(_ segments: [Segment], piece: Int = AudioFileSource.pieceSamples, failAt: Int? = nil, log: SourceLog,
             model: ModelLog, pieceDelay: TimeInterval = 0, onPiece: (@Sendable (Int) -> Void)? = nil) {
            self.segments = segments
            total = segments.reduce(0) { $0 + $1.samples }
            self.piece = piece
            self.failAt = failAt
            self.log = log
            self.model = model
            self.onPiece = onPiece
            self.pieceDelay = pieceDelay
        }

        var length: TimeInterval { Double(total) / 16_000 }
        var position: TimeInterval { Double(handed) / 16_000 }

        func next() throws(AudioFileFailure) -> [Float]? {
            if let failAt, handed >= failAt { throw .unreadable }
            guard handed < total else { return nil }
            let count = min(piece, total - handed)
            let samples = (handed..<(handed + count)).map { FileTests.sample($0, of: segments) }
            if pieceDelay > 0 { Thread.sleep(forTimeInterval: pieceDelay) }
            handed += count
            log.handedOut(handed, modelReached: Self.reached(model.projected))
            onPiece?(handed)
            return samples
        }

        /// The end of the last chunk the model has projected, for audio without silence: chunks of 15 s, 13 s apart.
        static func reached(_ projected: [Int]) -> Int {
            guard let last = projected.last else { return 0 }
            return (projected.count - 1) * (SpeechCore.chunkSamples - SpeechCore.chunkOverlapSamples) + last
        }
    }

    /// Every progress report, in order.
    final class ProgressLog: Sendable {
        private let list = Mutex<[FileSpeechProgress]>([])
        var all: [FileSpeechProgress] { list.withLock { $0 } }
        var report: @Sendable (FileSpeechProgress) -> Void { { [self] value in list.withLock { $0.append(value) } } }
    }

    func engine(_ log: ModelLog, loader: ModelLoader? = nil, dictionary: @escaping @Sendable (String?) -> DictionarySnapshot = { _ in .empty })
        -> SpeechEngine {
        SpeechEngine(loader: loader ?? fakeLoader(log), dictionary: dictionary)
    }

    /// Transcribes `source` within a time limit: its text, its failure, or nil when it hung. Cancelling the caller
    /// cancels the transcription.
    func transcribe(_ engine: SpeechEngine, progress: ProgressLog = ProgressLog(), within seconds: Double = 30,
                    _ open: @escaping AudioSourceOpener) async -> Result<String, FileSpeechFailure>? {
        let task = Task { () async -> Result<String, FileSpeechFailure> in
            do throws(FileSpeechFailure) {
                return .success(try await engine.transcribe(open: open, progress: progress.report))
            } catch {
                return .failure(error)
            }
        }
        return await withTaskCancellationHandler {
            await within(seconds) { await task.value }
        } onCancel: {
            task.cancel()
        }
    }

    func transcribe(_ engine: SpeechEngine, file: URL, progress: ProgressLog = ProgressLog()) async
        -> Result<String, FileSpeechFailure>? {
        await within(30) {
            do throws(FileSpeechFailure) {
                return .success(try await engine.transcribe(file: file, progress: progress.report))
            } catch {
                return .failure(error)
            }
        }
    }

    static let pausedSpeech: [Segment] = [.silence(2), .tone(9), .silence(4), .tone(20.5), .silence(1.2), .tone(17),
                                          .silence(6), .tone(3)]

    // MARK: - The text

    /// However the audio arrives, a file and the same audio as a recording give the same text: the same silence is
    /// compacted, the same chunks are cut and joined at the same seams.
    @Test func aFileGivesTheTextTheSameAudioGivesAsARecording() async throws {
        let log = ModelLog()
        let engine = engine(log)
        let recording = try #require(await SpeechEngineTests.transcribe(engine, Self.samples(Self.pausedSpeech))).get()
        #expect(!recording.isEmpty)
        for piece in [AudioFileSource.pieceSamples, 1000, 160_000] {
            let source: AudioSourceOpener = { SignalSource(Self.pausedSpeech, piece: piece, log: SourceLog(), model: log) }
            #expect(try #require(await transcribe(engine, source)).get() == recording, "In pieces of \(piece)")
        }
    }

    /// A file on disk, at another rate and with two channels, is read by the engine as the reader reads it.
    @Test func aFileOnDiskIsReadAsTheReaderReadsIt() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("signal.aiff")
        try Self.write(Self.samples([.tone(4), .silence(1), .tone(18)]), to: url, sampleRate: 44_100, channels: 2)
        let log = ModelLog()
        let engine = engine(log)
        let samples = try AudioFileReader.samples(contentsOf: url)
        let recording = try #require(await SpeechEngineTests.transcribe(engine, samples)).get()
        #expect(!recording.isEmpty)
        let progress = ProgressLog()
        #expect(try #require(await transcribe(engine, file: url, progress: progress)).get() == recording)
        let length = 23.0
        guard case .transcribing(let read, let total)? = progress.all.last else {
            Issue.record("No progress")
            return
        }
        #expect(abs(total - length) < 0.01 && read == total, "Progress ends at the file's length")
    }

    /// The engine decodes a file with the words that apply everywhere, as a Run Log retry does, and restores their
    /// casing.
    @Test func theDictionaryIsTheOneForNoApp() async throws {
        let log = ModelLog()
        let asked = Mutex<[String?]>([])
        let zorblax = DictionaryEntry(text: "Zorblax", strength: 2)
        let engine = engine(log, dictionary: { app in
            asked.withLock { $0.append(app) }
            return DictionarySnapshot(revision: 1, entries: [zorblax])
        })
        let source: AudioSourceOpener = { SignalSource([.tone(3)], log: SourceLog(), model: log) }
        #expect(try #require(await transcribe(engine, source)).get() == "W0 Zorblax w2.")
        #expect(asked.withLock { $0 } == [nil], "The dictionary is asked once, for no app")
    }

    // MARK: - Memory and fairness

    /// A long quiet start is not held whole, and the text is still the one the same audio gives as a recording:
    /// whether speech follows it, or there is no speech at all and the file is read again as a recording would hear
    /// it, unchanged.
    @Test func aLongQuietStartGivesTheSameText() async throws {
        let log = ModelLog()
        let engine = engine(log)
        for segments: [Segment] in [[.hum(40), .tone(10), .silence(2)], [.silence(32), .tone(3)], [.hum(45)]] {
            let recording = try #require(await SpeechEngineTests.transcribe(engine, Self.samples(segments))).get()
            #expect(!recording.isEmpty)
            let opens = Mutex(0)
            let text = try #require(await transcribe(engine) {
                opens.withLock { $0 += 1 }
                return SignalSource(segments, log: SourceLog(), model: log)
            }).get()
            #expect(text == recording)
            let speech = segments.contains { if case .tone = $0 { true } else { false } }
            #expect(opens.withLock { $0 } == (speech ? 1 : 2), "Read again only when there was no speech")
        }
    }

    /// However long the file, the engine reads the next piece only when the last has gone into the chunker: what it
    /// has read is never more than a chunk and a piece ahead of what the model has seen.
    @Test func readPiecesNeverPileUpAheadOfTheModel() async throws {
        let log = ModelLog()
        let engine = engine(log)
        let sources = SourceLog()
        let minutes = 6.0
        let source: AudioSourceOpener = { SignalSource([.tone(minutes * 60)], log: sources, model: log) }
        let text = try #require(await transcribe(engine, within: 120, source)).get()
        #expect(text.hasPrefix("W0 w1 w2") && text.hasSuffix("w\(Int(minutes * 60) - 1)."))
        #expect(sources.handed == Signals.s(minutes * 60), "The whole file was read")
        #expect(log.projected.count > 20, "The file spans many chunks")
        // The silence compactor holds back less than one 10 ms frame, which it judges whole.
        #expect(sources.mostAhead <= SpeechCore.chunkSamples + AudioFileSource.pieceSamples + SilenceCompactor.frameSamples,
                "Read \(sources.mostAhead) samples ahead of the model")
    }

    /// A dictation made while a long file is transcribed is served between the file's chunks: it waits for the chunk
    /// in progress, not for the file, even when the file's task has the higher priority.
    @Test func aDictationDuringALongFileFinishesFirst() async throws {
        let log = ModelLog()
        let engine = engine(log, loader: fakeLoader(log, projectDelay: 0.02))
        await prepare(engine)
        let opened = Mutex(false)
        let dictation = Mutex<Task<Result<SpeechResult, SpeechFailure>?, Never>?>(nil)
        // Once the file's first chunk has been transcribed, a dictation of 2 s starts and finishes, from the engine's
        // own executor, so it is certainly waiting while the file is still being read.
        let source: AudioSourceOpener = { SignalSource([.tone(400)], log: SourceLog(), model: log, onPiece: { _ in
            guard log.projected.count == 1, !opened.withLock({ state in defer { state = true }; return state }) else {
                return
            }
            let stream = engine.openStream(SpeechStreamOptions())
            stream.append(EngineTests.speech(2))
            dictation.withLock { $0 = Task(priority: .medium) { await finish(stream, within: 60) } }
        }) }
        let file = Task(priority: .userInitiated) { await transcribe(engine, within: 120, source) }
        let fileText = try #require(await file.value).get()
        let dictated = try #require(await dictation.withLock({ $0 })?.value)
        #expect(try dictated.get().text == "W0 w1.")
        #expect(fileText.hasSuffix("w399."))
        // The dictation's one chunk is 2 s long; the file's are 15 s, but for its last.
        let order = log.projected
        let dictationChunk = try #require(order.firstIndex(of: Signals.s(2)))
        #expect(dictationChunk < order.count - 3, "The dictation was transcribed while the file had chunks to go")
    }

    /// A long silence before a file's first speech cuts no chunk, but a dictation made meanwhile still does not wait
    /// for the file: the engine gives way after each chunk's worth of audio it reads.
    @Test func aDictationDuringALongSilenceIsNotHeldUp() async throws {
        let log = ModelLog()
        let engine = engine(log)
        await prepare(engine)
        let sources = SourceLog()
        let opened = Mutex(false)
        let finishedAt = Mutex<Int?>(nil)
        let total = Signals.s(603)
        let source: AudioSourceOpener = {
            SignalSource([.silence(600), .tone(3)], log: sources, model: log, pieceDelay: 0.001, onPiece: { handed in
                guard handed >= Signals.s(20), !opened.withLock({ state in defer { state = true }; return state }) else {
                    return
                }
                let stream = engine.openStream(SpeechStreamOptions())
                stream.append(EngineTests.speech(2))
                Task {
                    _ = await finish(stream, within: 60)
                    finishedAt.withLock { $0 = sources.handed }
                }
            })
        }
        // The silence keeps its last 0.3 s, so the tone is heard from 0.3 s to 3.3 s: four whole seconds.
        #expect(try #require(await transcribe(engine, within: 120, source)).get() == "W0 w1 w2 w3.")
        await within { while finishedAt.withLock({ $0 }) == nil { try? await Task.sleep(for: .milliseconds(5)) } }
        let at = try #require(finishedAt.withLock { $0 })
        #expect(at < total, "The dictation finished after \(at) of the file's \(total) samples had been read")
    }

    // MARK: - Progress

    /// While the model prepares the file says so; then the amount read rises, never past the length, and ends at it.
    @Test func progressRisesToTheLength() async throws {
        let log = ModelLog()
        let release = DispatchSemaphore(value: 0)
        let engine = engine(log, loader: fakeLoader(log, wait: release))
        let progress = ProgressLog()
        let source: AudioSourceOpener = { SignalSource([.tone(40)], log: SourceLog(), model: log) }
        let task = Task { await transcribe(engine, progress: progress, source) }
        let deadline = ContinuousClock.now + .seconds(10)
        while progress.all.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(progress.all == [.preparingModel], "It says the model is preparing while it waits")
        release.signal()
        #expect(try #require(await task.value).get().hasSuffix("w39."))
        let reports = progress.all.dropFirst()
        #expect(reports.first == .transcribing(read: 0, length: 40))
        #expect(reports.last == .transcribing(read: 40, length: 40))
        var last = -1.0
        for report in reports {
            guard case .transcribing(let read, let length) = report else {
                Issue.record("Preparing again after transcribing began")
                continue
            }
            #expect(length == 40 && read <= length && read >= last)
            last = read
        }
        #expect(reports.count > 10, "Progress is reported as the file is read")

        let ready = ProgressLog()
        let again: AudioSourceOpener = { SignalSource([.tone(2)], log: SourceLog(), model: log) }
        _ = await transcribe(engine, progress: ready, again)
        #expect(ready.all.first == .transcribing(read: 0, length: 2), "A ready model is not reported as preparing")
    }

    /// The amount read is never shown as more than the length the file gave, which for a compressed file can be an
    /// estimate that falls short.
    @Test func readIsNeverMoreThanTheLength() async throws {
        final class ShortEstimate: AudioPieceSource {
            let inner: SignalSource
            init(_ inner: SignalSource) { self.inner = inner }
            var length: TimeInterval { inner.length - 1 }
            var position: TimeInterval { inner.position }
            func next() throws(AudioFileFailure) -> [Float]? { try inner.next() }
        }
        let log = ModelLog()
        let engine = engine(log)
        await prepare(engine)
        let progress = ProgressLog()
        let text = try await engine.transcribe(open: { ShortEstimate(SignalSource([.tone(5)], log: SourceLog(), model: log)) },
                                               progress: progress.report)
        #expect(text == EngineTests.words(seconds: 5))
        for case .transcribing(let read, let length) in progress.all { #expect(read <= length && length == 4) }
        #expect(progress.all.last == .transcribing(read: 4, length: 4))
    }

    // MARK: - Cancelling and failing

    /// Cancelling stops the file before the next piece or chunk and gives no text; the rest of it is never read.
    @Test func cancellingStopsTheFile() async throws {
        let log = ModelLog()
        let engine = engine(log, loader: fakeLoader(log, projectDelay: 0.02))
        let sources = SourceLog()
        let source: AudioSourceOpener = { SignalSource([.tone(600)], log: sources, model: log) }
        let task = Task { await transcribe(engine, within: 120, source) }
        let deadline = ContinuousClock.now + .seconds(20)
        while log.projected.count < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        #expect(await task.value == .failure(.cancelled))
        #expect(sources.handed < Signals.s(600) / 2, "The rest of the file was not read")
        let projected = log.projected.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.projected.count == projected, "Nothing more is transcribed after it ends")
    }

    /// A file waiting for a model that is still preparing gives up at once when it is cancelled.
    @Test func cancellingWhilePreparingEndsAtOnce() async throws {
        let log = ModelLog()
        let release = DispatchSemaphore(value: 0)
        let engine = engine(log, loader: fakeLoader(log, wait: release))
        let progress = ProgressLog()
        let source: AudioSourceOpener = { SignalSource([.tone(3)], log: SourceLog(), model: log) }
        let task = Task { await transcribe(engine, progress: progress, source) }
        let deadline = ContinuousClock.now + .seconds(10)
        while progress.all.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        #expect(await task.value == .failure(.cancelled), "The model is still preparing")
        release.signal()
        await prepare(engine)
        #expect(log.loads == 1)
    }

    @Test func aTaskCancelledBeforeItStartsReadsNothing() async throws {
        let log = ModelLog()
        let engine = engine(log)
        let sources = SourceLog()
        let source: AudioSourceOpener = { SignalSource([.tone(3)], log: sources, model: log) }
        let task = Task { () async -> FileSpeechFailure? in
            withUnsafeCurrentTask { $0?.cancel() }
            do throws(FileSpeechFailure) {
                _ = try await engine.transcribe(open: source, progress: { _ in })
                return nil
            } catch {
                return error
            }
        }
        #expect(await task.value == .cancelled)
        #expect(sources.handed == 0)
    }

    @Test func withoutTheModelItFailsAsTheEngineDoes() async throws {
        let log = ModelLog()
        let missing = SpeechEngine(loader: nil, dictionary: { _ in .empty })
        #expect(await transcribe(missing) { SignalSource([.tone(1)], log: SourceLog(), model: log) }
                == .failure(.engineUnavailable(.modelMissing)))

        let failing = engine(log, loader: fakeLoader(log, failures: 1, failure: .modelCorrupt))
        #expect(await transcribe(failing) { SignalSource([.tone(1)], log: SourceLog(), model: log) }
                == .failure(.engineUnavailable(.modelCorrupt)))
        #expect(await transcribe(failing) { SignalSource([.tone(1)], log: SourceLog(), model: log) }
                == .failure(.engineUnavailable(.modelCorrupt)), "A file does not start a new attempt after a failure")
        #expect(log.loads == 1)
        await prepare(failing)
        #expect(try #require(await transcribe(failing) { SignalSource([.tone(1)], log: SourceLog(), model: log) }).get()
                == "W0.", "Once a new attempt succeeds, files are transcribed")
    }

    /// A file damaged part way through gives no text at all, never the text so far.
    @Test func damagePartWayGivesNoText() async throws {
        let log = ModelLog()
        let engine = engine(log)
        let source: AudioSourceOpener = { SignalSource([.tone(60)], failAt: Signals.s(40), log: SourceLog(), model: log) }
        #expect(await transcribe(engine, source) == .failure(.unreadable))
    }

    /// A file is read where it is; one that cannot be opened, or opens but is not audio, fails before the model is
    /// even needed.
    @Test func filesThatCannotBeOpenedOrRead() async throws {
        let directory = try scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: directory.appendingPathComponent("locked.wav").path)
            try? FileManager.default.removeItem(at: directory)
        }
        let missing = SpeechEngine(loader: nil, dictionary: { _ in .empty })
        let text = directory.appendingPathComponent("notes.txt")
        try Data("Invented words, not audio.\n".utf8).write(to: text)
        let locked = directory.appendingPathComponent("locked.wav")
        try Self.write(Self.samples([.tone(1)]), to: locked, sampleRate: 16_000, channels: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let progress = ProgressLog()
        #expect(await transcribe(missing, file: directory.appendingPathComponent("absent.wav"), progress: progress)
                == .failure(.cannotOpen))
        #expect(await transcribe(missing, file: directory, progress: progress) == .failure(.cannotOpen))
        #expect(await transcribe(missing, file: locked, progress: progress) == .failure(.cannotOpen))
        #expect(await transcribe(missing, file: text, progress: progress) == .failure(.unreadable))
        #expect(progress.all.isEmpty, "Nothing waits for the model")
    }

    // MARK: - Corrections

    /// A file is not a recording: it keeps nothing for a correction, and leaves a dictation's kept audio alone.
    @Test func aFileLeavesADictationsCorrectionAlone() async throws {
        let log = ModelLog()
        let engine = engine(log)
        let stream = engine.openStream(SpeechStreamOptions(retainForCorrection: true))
        stream.append(EngineTests.speech(3))
        let result = try #require(await finish(stream)).get()
        let id = try #require(result.correctionID)
        let held = await engine.heldProjections()
        #expect(held > 0)
        let source: AudioSourceOpener = { SignalSource([.tone(20)], log: SourceLog(), model: log) }
        _ = try #require(await transcribe(engine, source)).get()
        #expect(await engine.heldProjections() == held, "The file kept nothing and released nothing")
        let suggestion = await engine.suggestCorrection(typed: "W0 w1 w2.", edited: "W0 zorblax w2.", correctionID: id,
                                                        ignore: [], isLast: true, check: engine.beginCorrectionCheck())
        #expect(suggestion?.word == "zorblax", "The dictation's audio is still there for its suggestion")
    }

    // MARK: - Helpers

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes 16 kHz `samples` as a 32-bit float file at `sampleRate` with `channels`, every channel the same.
    static func write(_ samples: [Float], to url: URL, sampleRate: Double, channels: AVAudioChannelCount) throws {
        let source = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                                interleaved: false))
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                channels: channels, interleaved: false))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)))
        input.frameLength = input.frameCapacity
        let channel = try #require(input.floatChannelData)[0]
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        let capacity = AVAudioFrameCount(Double(samples.count) * sampleRate / 16_000) + 1024
        let output = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity))
        let converter = try #require(AVAudioConverter(from: source, to: target))
        var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given {
                status.pointee = .endOfStream
                return nil
            }
            given = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        var settings = target.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        try AVAudioFile(forWriting: url, settings: settings).write(from: output)
    }
}
