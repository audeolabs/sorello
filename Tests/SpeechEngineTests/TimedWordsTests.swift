import DictationCore
import DictionaryKit
import Foundation
import Testing
@testable import SpeechEngine

/// A screen note's narration (ARCHITECTURE.md, section 14, "The note", step 1): a file's words with their times in
/// the file, with the fake model, which hears a word at every whole second of what it is given.
struct TimedWordsTests {
    typealias Segment = FileTests.Segment

    func words(_ segments: [Segment], log: ModelLog = ModelLog()) async throws -> [TimedWord] {
        let engine = SpeechEngine(loader: fakeLoader(log), dictionary: { _ in .empty })
        let result = await within(30) { () async -> Result<[TimedWord], FileSpeechFailure> in
            do throws(FileSpeechFailure) {
                return .success(try await engine.transcribeWords(open: {
                    FileTests.SignalSource(segments, log: FileTests.SourceLog(), model: log)
                }))
            } catch {
                return .failure(error)
            }
        }
        return try #require(result).get()
    }

    @Test func eachWordHasItsTimeInTheFileSilenceIncluded() async throws {
        // Compacted, the leading silence would shrink to 0.3 s and every later word would move earlier.
        let heard = try await words([.silence(4), .tone(3)])
        #expect(heard.map(\.time) == [0, 1, 2, 3, 4, 5, 6])
        #expect(heard.first?.text == "W0")
        #expect(heard.last?.text == "w6.")
    }

    @Test func wordsAcrossChunksAreJoinedOnceInOrder() async throws {
        let heard = try await words([.tone(20), .silence(14), .tone(2)])
        #expect(heard.map(\.time) == (0..<36).map(Double.init))
        #expect(Set(heard.map(\.time)).count == heard.count)
    }

    @Test func aFileThatCannotBeOpenedFailsAtOnce() async throws {
        let engine = SpeechEngine(loader: fakeLoader(ModelLog()), dictionary: { _ in .empty })
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-note-\(UUID()).mov")
        await #expect(throws: FileSpeechFailure.cannotOpen) { try await engine.transcribeWords(file: missing) }
    }
}
