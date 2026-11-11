import DictationCore
import Foundation
import Testing
@testable import SorelloApp

@Suite struct SelfTestPartsTests {
    @Test func aFileIsHeardAtThePaceItWasSpoken() async throws {
        let clock = ManualClock()
        let capture = FileCapture(clock: clock)
        capture.queue([Float](repeating: 0.1, count: 3_200 + 800))
        let started = clock.now
        let playback = try await capture.start(CaptureRequest())
        var chunks: [AudioChunk] = []
        var events = playback.events.makeAsyncIterator()
        for _ in 0..<3 {
            for _ in 0..<200 where clock.sleeperCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
            clock.advance(by: 0.1)
            if case .chunk(let chunk) = await events.next() { chunks.append(chunk) }
        }
        #expect(chunks.map(\.samples.count) == [1_600, 1_600, 800])
        #expect(chunks.map { (($0.time - started) * 10).rounded() } == [1, 2, 3])
        await capture.waitUntilPlayed()
        await playback.stop()
        #expect(await events.next() == nil)
        // Nothing queued: no microphone to start.
        await #expect(throws: CaptureFailure.noInputDevice) { try await capture.start(CaptureRequest()) }
    }

    @Test func theRecorderComposesForAnUnreadableCursorAndPastesNothing() async {
        let inserter = RecordingInserter()
        let outcome = await inserter.insert(restoreClipboard: true) { destination in
            guard case .cursor(nil, nil) = destination else { return ComposedInsertion(text: "wrong") }
            return ComposedInsertion(text: "Hello there.", pressEnter: true)
        }
        #expect(outcome == .inserted)
        #expect(inserter.inserted == [ComposedInsertion(text: "Hello there.", pressEnter: true)])
        let nothing = await inserter.insert(restoreClipboard: true) { _ in ComposedInsertion(text: "") }
        #expect(nothing == .nothingToInsert)
    }
}
