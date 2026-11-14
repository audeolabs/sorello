import AVFoundation
import DictationCore
import Foundation
import SpeechEngine
import Synchronization
import Testing
import TextRules
@testable import FileTranscription

/// The one path a file takes to text (ARCHITECTURE.md, section 5, "Transcribing a file"): the engine's transcript,
/// then the user's rules as a Run Log retry applies them, and failures told apart without carrying anything the file
/// holds. The engine is faked here; its own reading of files is tested in SpeechEngineTests. Text is invented.
struct FileTranscriberTests {
    /// Stands in for the engine: reports `reports`, then gives `text` or throws `failure`.
    struct FakeSpeech: FileSpeech {
        var text = ""
        var failure: FileSpeechFailure?
        var reports: [FileSpeechProgress] = []
        var waitsForCancel = false

        func transcribe(file: URL, progress: @escaping @Sendable (FileSpeechProgress) -> Void)
            async throws(FileSpeechFailure) -> String {
            for report in reports { progress(report) }
            if waitsForCancel {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                throw .cancelled
            }
            if let failure { throw failure }
            return text
        }
    }

    final class Reports: Sendable {
        private let list = Mutex<[FileTranscriptionProgress]>([])
        var all: [FileTranscriptionProgress] { list.withLock { $0 } }
        var report: @Sendable (FileTranscriptionProgress) -> Void { { [self] value in list.withLock { $0.append(value) } } }
    }

    static let file = URL(fileURLWithPath: "/nonexistent/invented.m4a")

    static func rules(numbers: Bool = true, delimiters: Bool = false, pressEnter: Bool = false,
                      macros: [VoiceMacro] = [], tag: String = "[dictated]") -> TextRuleOptions {
        TextRuleOptions(macros: macros, pressEnterCommand: pressEnter, spokenNumbers: numbers,
                        spokenDelimiters: delimiters, promptTag: tag)
    }

    func transcribe(_ speech: FakeSpeech, rules: TextRuleOptions?, fits: Bool = true,
                    reports: Reports = Reports()) async -> Result<String, FileTranscriptionFailure> {
        do throws(FileTranscriptionFailure) {
            let transcriber = FileTranscriber(speech: speech, modelFitsThisMac: fits)
            return .success(try await transcriber.transcribe(Self.file, rules: rules, progress: reports.report))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - The text

    /// The rules apply as a Run Log retry applies them: in plain style, with no text around a cursor.
    @Test func theRulesApplyAsARetrysDo() async throws {
        let heard = "We counted twenty three herons, quote wading end quote, press enter"
        let rules = Self.rules(delimiters: true, pressEnter: true, tag: "[spoken]")
        let text = try await transcribe(FakeSpeech(text: heard), rules: rules).get()
        #expect(text == DictationRules.process(heard, options: rules, promptStyle: false, before: nil, after: nil).text)
        #expect(text.contains("23 herons"), "Spoken numbers become digits")
        #expect(!text.lowercased().contains("press enter"), "A trailing press enter is removed when the rule is on")
        #expect(!text.contains("[spoken]"), "A file is never in prompt style")
    }

    @Test func aMacroReplacesAWholeFile() async throws {
        let macro = VoiceMacro(command: "sign off for today", text: "Invented closing line.")
        let text = try await transcribe(FakeSpeech(text: "Sign off for today."), rules: Self.rules(macros: [macro])).get()
        #expect(text == "Invented closing line.")
    }

    /// With the rules off a trailing "press enter" stays, as every other word does.
    @Test func withoutRulesTheTranscriptIsAsHeard() async throws {
        let heard = "Twenty three herons, press enter"
        #expect(try await transcribe(FakeSpeech(text: heard), rules: nil).get() == heard)
        let off = Self.rules(numbers: false)
        #expect(try await transcribe(FakeSpeech(text: heard), rules: off).get() == heard, "Rules that are off change nothing")
    }

    @Test func noWordsHeardIsNoText() async throws {
        #expect(try await transcribe(FakeSpeech(text: ""), rules: Self.rules(pressEnter: true)).get() == "")
        #expect(try await transcribe(FakeSpeech(text: ""), rules: nil).get() == "")
    }

    // MARK: - Progress and failures

    @Test func progressIsPassedOn() async throws {
        let reports = Reports()
        let speech = FakeSpeech(text: "Invented.", reports: [.preparingModel, .transcribing(read: 0, length: 12.5),
                                                             .transcribing(read: 12.5, length: 12.5)])
        _ = try await transcribe(speech, rules: nil, reports: reports).get()
        #expect(reports.all == [.preparingModel, .transcribing(read: 0, length: 12.5),
                                .transcribing(read: 12.5, length: 12.5)])
    }

    @Test(arguments: [
        (FileSpeechFailure.cannotOpen, true, FileTranscriptionFailure.cannotOpen),
        (.unreadable, true, .unreadable),
        (.engineUnavailable(.modelMissing), true, .modelMissing),
        (.engineUnavailable(.modelMissing), false, .noModelForThisMac),
        (.engineUnavailable(.modelCorrupt), true, .modelUnavailable),
        (.engineUnavailable(.loadFailed), true, .modelUnavailable),
        (.failed, true, .failed),
        (.cancelled, true, .cancelled),
    ])
    func failuresAreToldApart(engine: FileSpeechFailure, fits: Bool, expected: FileTranscriptionFailure) async {
        #expect(await transcribe(FakeSpeech(failure: engine), rules: Self.rules(), fits: fits) == .failure(expected))
    }

    @Test func cancellingTheTaskCancelsIt() async {
        let task = Task { await transcribe(FakeSpeech(waitsForCancel: true), rules: nil) }
        task.cancel()
        #expect(await task.value == .failure(.cancelled))
    }

    // MARK: - Over the real engine

    /// The real engine with no model on the Mac: a file is opened first, then the model is found missing, or found
    /// to have no build for this Mac.
    @Test func overAnEngineWithoutItsModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileTranscriberTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("tone.wav")
        try Self.writeTone(to: wav)
        for fits in [true, false] {
            let engine = SpeechEngine(modelDirectory: nil, storeDirectory: nil, dictionary: { _ in .empty })
            let transcriber = FileTranscriber(engine: engine, modelFitsThisMac: fits)
            await #expect(throws: fits ? FileTranscriptionFailure.modelMissing : .noModelForThisMac) {
                try await transcriber.transcribe(wav, rules: nil, progress: { _ in })
            }
            await #expect(throws: FileTranscriptionFailure.cannotOpen) {
                try await transcriber.transcribe(directory.appendingPathComponent("absent.wav"), rules: nil,
                                                 progress: { _ in })
            }
        }
    }

    /// One second of an invented tone, 16 kHz mono.
    static func writeTone(to url: URL) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                                interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channel = try #require(buffer.floatChannelData)[0]
        for index in 0..<16_000 { channel[index] = Float(0.1 * sin(2 * Double.pi * 440 * Double(index) / 16_000)) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }
}
