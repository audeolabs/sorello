import DictationCore
import DictionaryKit
import Foundation
import Synchronization
import Testing
@testable import SpeechEngine

/// A stream's progress feed (ARCHITECTURE.md, section 5, "Progress"), through the speech port with the fake model,
/// which hears "w<n>" at every whole second. Audio is an invented tone.
struct ProgressTests {
    /// Every report a feed holds, read until it ends; nil when it did not end in time.
    func reports(_ stream: any SpeechStreaming, sourceLocation: SourceLocation = #_sourceLocation) async
        -> [SpeechProgress]? {
        guard let feed = stream.progress else {
            Issue.record("The stream has no feed", sourceLocation: sourceLocation)
            return nil
        }
        return await within(sourceLocation: sourceLocation) {
            var reports: [SpeechProgress] = []
            for await report in feed { reports.append(report) }
            return reports
        }
    }

    /// The fake model's words for seconds `range`, the first of a recording capitalized and its last with a period.
    func words(_ range: Range<Int>, of seconds: Int) -> String {
        range.map { $0 == 0 ? "W0" : $0 == seconds - 1 ? "w\($0)." : "w\($0)" }.joined(separator: " ")
    }

    func append(_ recording: [Float], to stream: any SpeechStreaming, in pieces: [Int]) {
        var start = 0, index = 0
        while start < recording.count {
            let end = min(start + pieces[index % pieces.count], recording.count)
            stream.append(Array(recording[start..<end]))
            start = end
            index += 1
        }
    }

    @Test func aStreamThatDoesNotAskHasNoFeed() async throws {
        let engine = SpeechEngine(loader: fakeLoader(ModelLog()), dictionary: { _ in .empty })
        let stream = engine.openStream(SpeechStreamOptions())
        #expect(stream.progress == nil)
        stream.append(EngineTests.speech(16))
        #expect(try #require(await finish(stream)).get().text == EngineTests.words(seconds: 16))
    }

    /// However the audio is split into appends, the settled pieces, empty ones left out and joined by single spaces,
    /// are exactly the finished text, dictionary casing included, even where an entry of several words spans the
    /// place a chunk settles to. The feed is read only after `finish` has returned, so an unread feed holds the
    /// stream back in nothing.
    @Test func settledPiecesJoinToTheFinishedText() async throws {
        let entries = [DictionaryEntry(text: "W12 W13 W14", strength: 1), DictionaryEntry(text: "W25 W26", strength: 1),
                       DictionaryEntry(text: "W40", strength: 1)]
        let snapshot = DictionarySnapshot(revision: 1, entries: entries)
        let engine = SpeechEngine(loader: fakeLoader(ModelLog()), dictionary: { _ in snapshot })
        for seconds in [0.0, 0.5, 3, 14, 15, 16, 29, 31, 44, 60] {
            let recording = EngineTests.speech(seconds)
            let unasked = engine.openStream(SpeechStreamOptions())
            unasked.append(recording)
            let expected = try #require(await finish(unasked)).get().text
            for pieces in [[recording.count], [1, 159, 160, 4096], [16_000], [240_001, 7]] {
                let stream = engine.openStream(SpeechStreamOptions(reportsProgress: true))
                append(recording, to: stream, in: pieces)
                let result = try #require(await finish(stream)).get()
                #expect(result.text == expected, "\(seconds) s in pieces of \(pieces): the same text as without a feed")
                let reports = try #require(await reports(stream))
                let settled = reports.map(\.settled).filter { !$0.isEmpty }.joined(separator: " ")
                #expect(settled == expected, "\(seconds) s in pieces of \(pieces)")
                #expect(reports.last?.provisional == "", "\(seconds) s: the last report leaves nothing provisional")
            }
        }
    }

    /// One report per chunk, while the audio is still arriving: the words no later chunk can reach, and the rest.
    @Test func reportsArriveAsChunksComplete() async throws {
        let engine = SpeechEngine(loader: fakeLoader(ModelLog()), dictionary: { _ in .empty })
        let stream = engine.openStream(SpeechStreamOptions(reportsProgress: true))
        let feed = try #require(stream.progress)
        let received = Mutex<[SpeechProgress]>([])
        let reader = Task {
            for await report in feed { received.withLock { $0.append(report) } }
        }
        append(EngineTests.speech(30), to: stream, in: [1600])
        let deadline = ContinuousClock.now + .seconds(10)
        while received.withLock({ $0.count }) < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Chunks start every 13 s. A word settles once it starts 0.4 s or more before the next chunk does.
        #expect(received.withLock { $0 } == [
            SpeechProgress(settled: words(0..<13, of: 30), provisional: "w13 w14."),
            SpeechProgress(settled: words(13..<26, of: 30), provisional: "w26 w27."),
        ], "Both complete chunks are reported before finish")
        #expect(try #require(await finish(stream)).get().text == EngineTests.words(seconds: 30))
        _ = await within { await reader.value }
        #expect(received.withLock { $0 }.last == SpeechProgress(settled: words(26..<30, of: 30), provisional: ""),
                "Finish sends the last piece")
        #expect(received.withLock { $0.count } == 3)
    }

    /// Casing an entry of several words could still change keeps its words provisional until it cannot.
    @Test func casingThatCouldStillChangeStaysProvisional() async throws {
        let snapshot = DictionarySnapshot(revision: 1, entries: [DictionaryEntry(text: "W12 W13", strength: 1)])
        let engine = SpeechEngine(loader: fakeLoader(ModelLog()), dictionary: { _ in snapshot })
        let stream = engine.openStream(SpeechStreamOptions(reportsProgress: true))
        stream.append(EngineTests.speech(16))
        #expect(try #require(await finish(stream)).get().text == words(0..<12, of: 16) + " W12 W13 w14 w15.")
        let reports = try #require(await reports(stream))
        #expect(reports.first == SpeechProgress(settled: words(0..<12, of: 16), provisional: "W12 W13 w14."))
        #expect(reports.last == SpeechProgress(settled: "W12 W13 w14 w15.", provisional: ""))
    }

    /// A cancel ends the feed at once, and nothing is reported after it, even by the chunk the model was busy with.
    @Test func aCancelledStreamReportsNothingMore() async throws {
        let model = HeldModel(log: ModelLog())
        let engine = SpeechEngine(loader: { model }, dictionary: { _ in .empty })
        await prepare(engine)
        let stream = engine.openStream(SpeechStreamOptions(reportsProgress: true))
        stream.append(EngineTests.speech(31))
        #expect(await within { await model.entered() } != nil, "The first chunk reached the model")
        stream.cancel()
        let reports = await reports(stream)
        model.release()
        await engine.waitUntilModelWorkEnds()
        #expect(reports == [], "The feed ended with the cancel")
        #expect(await finish(stream) == .failure(.cancelled))
    }

    /// A cancel that lands after the last piece is made, but before `finish` has its result, wins: the feed ends
    /// without a last report.
    @Test func aCancelBeforeDeliveryLeavesNoLastReport() async throws {
        let streams = Mutex<[UInt64: any SpeechStreaming]>([:])
        let engine = SpeechEngine(loader: fakeLoader(ModelLog()), dictionary: { _ in .empty }, beforeDelivery: { id in
            streams.withLock { $0[id] }?.cancel()
        })
        let stream = engine.openStream(SpeechStreamOptions(reportsProgress: true))
        let id = try #require((stream as? SpeechStream)?.id)
        streams.withLock { $0[id] = stream }
        stream.append(EngineTests.speech(3))
        #expect(await finish(stream) == .failure(.cancelled))
        #expect(await reports(stream) == [])
    }

    /// A stream that fails ends its feed without a last report; what it settled before stays as it was.
    @Test func aFailedStreamKeepsWhatItSettled() async throws {
        let engine = SpeechEngine(loader: fakeLoader(ModelLog()), dictionary: { _ in .empty })
        let stream = engine.openStream(SpeechStreamOptions(reportsProgress: true))
        var recording = EngineTests.speech(31)
        // Only the second chunk hears it.
        recording[20 * 16_000] = .nan
        stream.append(recording)
        #expect(await finish(stream) == .failure(.failed))
        #expect(await reports(stream) == [SpeechProgress(settled: words(0..<13, of: 31), provisional: "w13 w14.")])
    }

    /// An engine that cannot prepare ends the feed too.
    @Test func aStreamWithoutAModelEndsItsFeed() async throws {
        let engine = SpeechEngine(modelDirectory: nil, storeDirectory: nil, dictionary: { _ in .empty })
        let stream = engine.openStream(SpeechStreamOptions(reportsProgress: true))
        stream.append(EngineTests.speech(16))
        #expect(await finish(stream) == .failure(.engineUnavailable(.modelMissing)))
        #expect(await reports(stream) == [])
    }
}
