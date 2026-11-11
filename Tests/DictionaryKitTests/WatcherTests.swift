import Foundation
import Testing
@testable import DictionaryKit

/// What the main actor heard from a watcher.
@MainActor
final class WatchLog {
    var edits: [(edit: CorrectionEdit, isLast: Bool, watch: UInt64)] = []
    var abandons = 0
}

/// Blocks the calling thread (the main thread, in these tests) so nothing queued for the main actor runs meanwhile.
func blockThread(for seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
}

/// The live watcher on its own queue, with real time (DESIGN §3.5).
@MainActor
@Suite(.serialized)
struct WatcherTests {
    private func watcher(_ reader: FakeTextFieldReader, log: WatchLog,
                         attempts: [TimeInterval] = CorrectionWatcher.startAttempts) -> CorrectionWatcher {
        CorrectionWatcher(reader: reader, startAttempts: attempts,
                          onEdit: { edit, isLast, watch in log.edits.append((edit, isLast, watch)) },
                          onAbandon: { log.abandons += 1 })
    }

    /// What the inserter reads before it pastes: the focused field and where its selection starts.
    private func anchor(_ watcher: CorrectionWatcher, _ reader: FakeTextFieldReader,
                        expecting expected: UInt64? = nil) throws -> CorrectionAnchor? {
        let target = try #require(reader.captureFocusedTextField())
        return watcher.anchor(target: target, insertionPoint: reader.selectedRange(target)?.location,
                              expecting: expected ?? watcher.currentGeneration)
    }

    /// Anchors and starts a watch on a field that already shows the paste.
    private func started(_ reader: FakeTextFieldReader, log: WatchLog) async throws -> CorrectionWatcher {
        let watcher = watcher(reader, log: log)
        let anchored = try #require(try anchor(watcher, reader))
        watcher.start(anchored, pasted: "cart", correctionID: 7)
        await waitUntil(1) { !reader.rangeReads.isEmpty }
        return watcher
    }

    @Test func staleContextsTouchNothing() async throws {
        let reader = FakeTextFieldReader("Note: ")
        reader.paste("cart")
        let log = WatchLog()
        let watcher = watcher(reader, log: log)

        // A paste still waiting when a new recording starts gets no anchor and is never watched.
        let stale = watcher.currentGeneration
        watcher.cancel()
        #expect(try anchor(watcher, reader, expecting: stale) == nil, "A stale context gets no anchor")
        await waitUntil(0.4)
        #expect(reader.rangeReads.isEmpty, "Nothing is read for a stale paste")

        // An anchor cancelled before the watch starts never begins watching.
        let cancelled = try #require(try anchor(watcher, reader))
        watcher.cancel()
        watcher.start(cancelled, pasted: "cart", correctionID: 7)
        await waitUntil(0.4)
        #expect(reader.rangeReads.isEmpty, "A cancelled anchor never starts")

        // A newer anchor ends the watch an older one started.
        let first = try #require(try anchor(watcher, reader))
        watcher.start(first, pasted: "cart", correctionID: 7)
        await waitUntil(1) { !reader.rangeReads.isEmpty }
        let second = try #require(try anchor(watcher, reader))
        #expect(!watcher.isCurrent(first.generation) && watcher.isCurrent(second.generation))
        let reads = reader.rangeReads.count
        await waitUntil(1.2)
        #expect(reader.rangeReads.count == reads, "The older watch stops reading")

        // A current one begins, and a cancel ends all further reads.
        let current = try #require(try anchor(watcher, reader))
        watcher.start(current, pasted: "cart", correctionID: 7)
        await waitUntil(1) { reader.rangeReads.count > reads }
        #expect(reader.rangeReads.count == reads + 1)
        watcher.cancel()
        await waitUntil(1.4)
        #expect(reader.rangeReads.count == reads + 1)
    }

    /// The cleanup a cancel, an anchor or a claim asks for may run late, after a newer watch has started; it stops
    /// only watches older than the one it was asked for.
    @Test func lateCleanupLeavesANewerWatchAlone() async throws {
        let reader = FakeTextFieldReader("Note: ")
        reader.paste("cart")
        let log = WatchLog()
        let watcher = watcher(reader, log: log)
        let older = watcher.currentGeneration
        let anchored = try #require(try anchor(watcher, reader))
        watcher.start(anchored, pasted: "cart", correctionID: 7)
        await waitUntil(1) { !reader.rangeReads.isEmpty }
        // A cleanup for something older than this watch, arriving now, changes nothing.
        await watcher.stop(before: older + 1)
        let reads = reader.rangeReads.count
        await waitUntil(1.2) { reader.rangeReads.count > reads }
        #expect(reader.rangeReads.count > reads, "The newer watch goes on reading")
        // One for this watch stops it.
        await watcher.stop(before: anchored.generation + 1)
        await waitUntil(0.2)
        let stopped = reader.rangeReads.count
        await waitUntil(1.2)
        #expect(reader.rangeReads.count == stopped)
    }

    @Test func reportsAndContinues() async throws {
        let reader = FakeTextFieldReader("Note: ")
        reader.paste("cart")
        let log = WatchLog()
        let watcher = try await started(reader, log: log)
        reader.replace("cart", with: "chart")
        await waitUntil(4) { !log.edits.isEmpty }
        #expect(log.edits.count == 1)
        #expect(log.edits.first.map { s($0.edit.edited) == s("chart") && !$0.isLast && $0.edit.correctionID == 7 } == true,
                "A settled edit, not the last")
        let reads = reader.rangeReads.count
        await waitUntil(1.2) { reader.rangeReads.count > reads }
        #expect(reader.rangeReads.count > reads, "The watch continues after a report")
        watcher.cancel()
        await waitUntil(0.2)
        let afterCancel = reader.rangeReads.count
        await waitUntil(1.2)
        #expect(reader.rangeReads.count == afterCancel)
        #expect(log.edits.count == 1)
    }

    /// After an edit was reported, a field that turns secure or loses permission makes that watch stale on the
    /// watcher's own queue, before the main actor runs, so a check result already queued there cannot be used; the
    /// app is then told to stop. Losing focus does neither, and a cancelled watch is left alone.
    @Test func forbiddenStopAbandonsReportedEdits() async throws {
        struct Run { var edits: [Bool] = [], abandons = 0, staleBeforeMain = false, claimed = false }
        func run(_ change: (FakeTextFieldReader) -> Void, cancelFirst: Bool = false) async throws -> Run {
            let reader = FakeTextFieldReader("Note: ")
            reader.paste("cart")
            let log = WatchLog()
            let watcher = try await started(reader, log: log)
            reader.replace("cart", with: "chart")
            await waitUntil(4) { !log.edits.isEmpty }
            guard let watch = log.edits.first?.watch else {
                Issue.record("No edit was reported")
                return Run()
            }
            if cancelFirst { watcher.cancel() }
            change(reader)
            // The main thread stays blocked through the next poll.
            blockThread(for: 0.8)
            blockThread(for: 2) { cancelFirst || !watcher.isCurrent(watch) }
            var result = Run()
            result.staleBeforeMain = !watcher.isCurrent(watch)
            // A result that arrives now cannot claim an abandoned watch.
            result.claimed = watcher.claim(watch)
            await waitUntil(1) { log.edits.count > 1 || log.abandons > 0 }
            await waitUntil(0.2)
            result.edits = log.edits.map(\.isLast)
            result.abandons = log.abandons
            return result
        }
        for (name, change) in [("A secure field", { (r: FakeTextFieldReader) in r.secure = true }),
                               ("Lost permission", { $0.trusted = false })] {
            let result = try await run(change)
            #expect(result.edits == [false] && result.abandons == 1 && result.staleBeforeMain && !result.claimed,
                    "\(name) abandons the watch on its queue, got \(result)")
        }
        let moved = try await run { $0.focused = false }
        #expect(moved.edits == [false] && moved.abandons == 0 && !moved.staleBeforeMain && moved.claimed,
                "Lost focus keeps the reported edit usable, got \(moved)")
        let stale = try await run({ $0.secure = true }, cancelFirst: true)
        #expect(stale.edits == [false] && stale.abandons == 0 && !stale.claimed,
                "A cancelled watch abandons nothing and cannot be claimed, got \(stale)")
    }

    /// Using a result claims its watch atomically. A claimed watch stops reading, cannot be claimed again, and is not
    /// abandoned by a later secure field.
    @Test func claimingAWatch() async throws {
        let reader = FakeTextFieldReader("Note: ")
        reader.paste("cart")
        let log = WatchLog()
        let watcher = try await started(reader, log: log)
        reader.replace("cart", with: "chart")
        await waitUntil(4) { !log.edits.isEmpty }
        let watch = try #require(log.edits.first?.watch)
        #expect(watcher.claim(watch), "A current watch is claimed")
        #expect(!watcher.claim(watch), "A claimed watch cannot be claimed again")
        await waitUntil(0.2)
        let reads = reader.rangeReads.count
        reader.secure = true
        await waitUntil(1.2)
        #expect(reader.rangeReads.count == reads)
        #expect(log.abandons == 0)
    }

    /// A browser can update a field's Accessibility text a moment after the paste. The start is tried again while the
    /// field still shows the old text or a read fails, up to the last attempt; any other failure, or a cancel, ends it.
    @Test func startRetriesWhileTheFieldCatchesUp() async throws {
        let schedule = CorrectionWatcher.startAttempts
        #expect(schedule.first == 0.15 && schedule.last == 2 && zip(schedule, schedule.dropFirst()).allSatisfy { $0 < $1 },
                "Attempts rise from 0.15 s to 2 s after the paste")
        let attempts: [TimeInterval] = [0.05, 0.3, 0.6]
        func start(_ reader: FakeTextFieldReader, log: WatchLog,
                   afterCapture: (FakeTextFieldReader) -> Void = { _ in }) async throws -> CorrectionWatcher {
            let watcher = watcher(reader, log: log, attempts: attempts)
            let anchored = try #require(try anchor(watcher, reader))
            afterCapture(reader)
            watcher.start(anchored, pasted: "cart", correctionID: 7)
            return watcher
        }

        // The field catches up only once the second attempt reads it: the change happens inside that read, so the
        // first attempt always sees the stale field.
        for (name, stale, settle) in [
            ("Old text", { (_: FakeTextFieldReader) in }, { @Sendable (r: FakeTextFieldReader) in r.paste("cart") }),
            ("Failed reads", { (r: FakeTextFieldReader) in r.paste("cart"); r.failReads = true },
             { @Sendable (r: FakeTextFieldReader) in r.failReads = false }),
        ] {
            let reader = FakeTextFieldReader("Note: ")
            reader.onCharacterCount = { [unowned reader] in if reader.countReads == 2 { settle(reader) } }
            let log = WatchLog()
            let watcher = try await start(reader, log: log, afterCapture: stale)
            // The third count is the watch's first poll, so the start has finished.
            await waitUntil(3) { reader.countReads >= 3 }
            reader.replace("cart", with: "chart")
            await waitUntil(4) { !log.edits.isEmpty }
            #expect(log.edits.count == 1 && log.edits.first.map { s($0.edit.edited) == s("chart") } == true,
                    "\(name): the second attempt starts the watch")
            watcher.cancel()
        }

        // A field that never catches up is tried once per attempt, then left alone.
        do {
            let reader = FakeTextFieldReader("Note: ")
            let log = WatchLog()
            let watcher = try await start(reader, log: log)
            await waitUntil(2) { reader.countReads >= attempts.count }
            await waitUntil(0.3)
            #expect(reader.countReads == attempts.count)
            reader.paste("cart")
            reader.replace("cart", with: "chart")
            await waitUntil(1.5)
            #expect(reader.countReads == attempts.count)
            #expect(log.edits.isEmpty, "No watch after the last attempt")
            watcher.cancel()
        }

        // A retry must find the paste where the selection started before it. A caret moved after an older copy of
        // the text is no match.
        do {
            let reader = FakeTextFieldReader("cart Note: ")
            reader.onCharacterCount = { [unowned reader] in
                guard reader.countReads == 2 else { return }
                reader.failReads = false
                reader.caret = 4
            }
            let log = WatchLog()
            let watcher = try await start(reader, log: log) { $0.failReads = true }
            await waitUntil(2) { reader.countReads >= attempts.count }
            reader.replace("cart", with: "chart")
            await waitUntil(2.5)
            #expect(reader.countReads == attempts.count)
            #expect(log.edits.isEmpty, "An older copy of the text is not watched")
            watcher.cancel()
        }

        // Without the selection from before the paste there is nothing to bind a retry to, so only the first attempt
        // runs.
        do {
            let reader = FakeTextFieldReader("Note: ")
            reader.paste("cart")
            reader.failReads = true
            reader.onCharacterCount = { [unowned reader] in if reader.countReads == 2 { reader.failReads = false } }
            let log = WatchLog()
            let watcher = try await start(reader, log: log)
            await waitUntil(1) { reader.countReads >= 1 }
            await waitUntil(1)
            #expect(reader.countReads == 1)
            #expect(log.edits.isEmpty, "No retry without an insertion point")
            watcher.cancel()
        }

        // Other failures are not retried.
        for (name, change) in [("Focus moved", { (r: FakeTextFieldReader) in r.focused = false }),
                               ("A secure field", { $0.secure = true }),
                               ("Lost permission", { $0.trusted = false })] {
            let reader = FakeTextFieldReader("Note: ")
            reader.paste("cart")
            let log = WatchLog()
            let watcher = try await start(reader, log: log, afterCapture: change)
            await waitUntil(1)
            #expect(reader.checks <= 1 && reader.countReads == 0, "\(name) is tried once, got \(reader.checks) checks")
            watcher.cancel()
        }

        // A cancel ends the attempts.
        do {
            let reader = FakeTextFieldReader("Note: ")
            let log = WatchLog()
            let watcher = try await start(reader, log: log)
            await waitUntil(1) { reader.countReads >= 1 }
            watcher.cancel()
            await waitUntil(0.1)
            let afterCancel = reader.countReads
            reader.paste("cart")
            reader.replace("cart", with: "chart")
            await waitUntil(2.2)
            #expect(reader.countReads == afterCancel)
            #expect(log.edits.isEmpty, "A cancelled start reports nothing")
        }
    }
}
