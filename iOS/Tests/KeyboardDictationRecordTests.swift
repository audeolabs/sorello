import Foundation

/// `KeyboardDictationRecord` and `keyboard-dictation.json` (ARCHITECTURE.md, "In-keyboard dictation (experiment)",
/// Record; "Files"). The host tests are built with the experiment compiled in.
enum KeyboardDictationRecordTests {
    static var tests: [TestCase] {
        [
            ("roundTripsThroughTheStore", testRoundTripsThroughTheStore),
            ("absentMalformedAndForeignRecordsRead", testAbsentMalformedAndForeignRecordsRead),
            ("missingFieldsDecodeAsUnknown", testMissingFieldsDecodeAsUnknown),
            ("holdsOnlyNumbersAndFixedNames", testHoldsOnlyNumbersAndFixedNames),
            ("stepsTrackThePeakAndTheLeastLeft", testStepsTrackThePeakAndTheLeastLeft),
            ("unfiniteFiguresAreWrittenAsUnknown", testUnfiniteFiguresAreWrittenAsUnknown),
            ("unfinishedMeansNoOutcomeFromAnotherProcess", testUnfinishedMeansNoOutcomeFromAnotherProcess),
            ("abandonedKeepsTheSteps", testAbandonedKeepsTheSteps),
            ("failuresMapToOutcomesAndWords", testFailuresMapToOutcomesAndWords),
            ("stagingFilesAreTaggedAndSurviveTheLaunchSweep", testStagingFilesAreTaggedAndSurviveTheLaunchSweep),
            ("ageSweepRemovesOldTaggedStagingFiles", testAgeSweepRemovesOldTaggedStagingFiles),
            ("laterWritesReplaceOnlyTheirOwnAttempt", testLaterWritesReplaceOnlyTheirOwnAttempt),
            ("abandonedRecordStaysAbandoned", testAbandonedRecordStaysAbandoned),
            ("onlyAnotherKnownProcessesUnfinishedRecordIsAbandoned", testOnlyAnotherKnownProcessesUnfinishedRecordIsAbandoned),
        ]
    }

    private static let processID = UUID(uuidString: "6F1A0C3E-0000-4000-8000-00000000AB01")!
    private static let attemptID = UUID(uuidString: "6F1A0C3E-0000-4000-8000-00000000AB02")!
    private static let tappedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private static func withStore(_ body: (SharedDictationStore) -> Void) {
        let root = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        body(SharedDictationStore(directory: SharedDictationStore.directory(inContainer: root)))
    }

    private static func sample(_ footprint: Double, peak: Double? = nil, available: Double) -> KeyboardMemorySample {
        KeyboardMemorySample(footprintMB: footprint, peakMB: peak ?? footprint, availableMB: available)
    }

    private static func fullRecord() -> KeyboardDictationRecord {
        var record = KeyboardDictationRecord(attemptID: attemptID, processID: processID, tappedAt: tappedAt, iosVersion: "27.0", warm: false)
        record.reach(.tapped, milliseconds: 0, memory: sample(40, available: 120))
        record.reach(.captureRequested, milliseconds: 3, memory: sample(41, available: 119))
        record.reach(.modelLoading, milliseconds: 4, memory: sample(41, available: 119))
        record.reach(.firstAudio, milliseconds: 410, memory: sample(44, available: 116))
        record.reach(.modelReady, milliseconds: 1_900, memory: sample(150, peak: 171, available: 12))
        record.reach(.stopped, milliseconds: 4_000, memory: sample(152, available: 10))
        record.reach(.transcribed, milliseconds: 4_300, memory: sample(153, available: 9))
        record.audioSeconds = 3.6
        record.captureSampleRate = 48_000
        record.preparationMilliseconds = 1_896
        record.stopToTextMilliseconds = 300
        record.stopToInsertionMilliseconds = 310
        record.textSource = .stream
        record.memoryWarnings = 1
        record.end(.text, milliseconds: 4_301, memory: sample(153, available: 9))
        record.reach(.inserted, milliseconds: 4_310, memory: sample(153, available: 9))
        return record
    }

    private static func testRoundTripsThroughTheStore() {
        withStore { store in
            let record = fullRecord()
            try! store.writeKeyboardDictation(record)
            TestSupport.expectEqual(store.readKeyboardDictation(), .value(record))
            TestSupport.expectEqual(store.keyboardDictationURL.lastPathComponent, "keyboard-dictation.json")
            TestSupport.expectEqual(store.keyboardDictationURL.deletingLastPathComponent().standardizedFileURL,
                                    store.directory.standardizedFileURL)
            // Each dictation overwrites it.
            var next = KeyboardDictationRecord(attemptID: attemptID, processID: processID, tappedAt: tappedAt + 60, iosVersion: "27.0", warm: true)
            next.reach(.tapped, milliseconds: 0, memory: sample(150, available: 12))
            try! store.writeKeyboardDictation(next)
            TestSupport.expectEqual(store.readKeyboardDictation(), .value(next))
            // Nothing else is left beside it.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
            TestSupport.expectEqual(names, ["keyboard-dictation.json"])
        }
    }

    private static func testAbsentMalformedAndForeignRecordsRead() {
        withStore { store in
            TestSupport.expectEqual(store.readKeyboardDictation(), .absent)
            try! FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            try! Data("{not json".utf8).write(to: store.keyboardDictationURL)
            TestSupport.expectEqual(store.readKeyboardDictation(), .unreadable)
            try! Data(#"{"schema":1,"steps":[{"step":"somethingNew"}]}"#.utf8).write(to: store.keyboardDictationURL)
            TestSupport.expectEqual(store.readKeyboardDictation(), .unreadable)
            try! Data(#"{"schema":2,"steps":"anything"}"#.utf8).write(to: store.keyboardDictationURL)
            TestSupport.expectEqual(store.readKeyboardDictation(), .incompatible)
        }
    }

    private static func testMissingFieldsDecodeAsUnknown() {
        withStore { store in
            try! FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            try! Data(#"{"schema":1}"#.utf8).write(to: store.keyboardDictationURL)
            guard let bare = store.readKeyboardDictation().value else { return TestSupport.expect(false, "a bare record is unreadable") }
            TestSupport.expectEqual(bare.steps, [])
            TestSupport.expect(bare.attemptID == nil && bare.processID == nil && bare.tappedAt == nil && bare.warm == nil && bare.outcome == nil
                               && bare.peakFootprintMB == nil && bare.memoryWarnings == nil, "a missing field is not unknown")
            try! Data(#"{"schema":1,"steps":[{"step":"tapped"}],"outcome":"abandoned"}"#.utf8).write(to: store.keyboardDictationURL)
            let partial = store.readKeyboardDictation().value
            TestSupport.expectEqual(partial?.steps, [.init(step: .tapped, milliseconds: nil, footprintMB: nil, availableMB: nil)])
            TestSupport.expectEqual(partial?.outcome, .abandoned)
        }
    }

    /// The file's keys are the contract's fixed names, and its values numbers, fixed names, the tap's date, the iOS
    /// version and the random run id: nothing that could carry audio, text, a field or an app.
    private static func testHoldsOnlyNumbersAndFixedNames() {
        withStore { store in
            try! store.writeKeyboardDictation(fullRecord())
            let data = try! Data(contentsOf: store.keyboardDictationURL)
            let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            TestSupport.expectEqual(Set(object.keys), [
                "schema", "attemptID", "processID", "tappedAt", "iosVersion", "warm", "steps", "peakFootprintMB", "leastAvailableMB",
                "audioSeconds", "captureSampleRate", "preparationMilliseconds", "stopToTextMilliseconds",
                "stopToInsertionMilliseconds", "textSource", "memoryWarnings", "outcome",
            ])
            let names = Set(KeyboardDictationRecord.Step.allCases.map(\.rawValue))
            for step in object["steps"] as! [[String: Any]] {
                TestSupport.expect(Set(step.keys).isSubset(of: ["step", "milliseconds", "footprintMB", "availableMB"]),
                                   "a step holds more than its figures")
                TestSupport.expect(names.contains(step["step"] as! String), "a step is not a fixed name")
            }
            TestSupport.expectEqual(KeyboardDictationRecord.Step.allCases.map(\.rawValue), [
                "tapped", "captureRequested", "firstAudio", "modelLoading", "modelReady", "firstChunkDecoded", "stopped",
                "transcribed", "inserted", "offered", "dropped", "ended",
            ])
            TestSupport.expectEqual(Set(KeyboardDictationRecord.Outcome.allCases.map(\.rawValue)), [
                "text", "noSpeech", "cancelled", "abandoned", "captureUnavailable", "startupTimeout",
                "captureLost", "modelFailed", "transcriptionFailed", "keyboardDismissed", "hostTookOver",
            ])
        }
    }

    private static func testStepsTrackThePeakAndTheLeastLeft() {
        let record = fullRecord()
        TestSupport.expectEqual(record.peakFootprintMB, 171)
        TestSupport.expectEqual(record.leastAvailableMB, 9)
        TestSupport.expectEqual(record.lastStep, .inserted)
        TestSupport.expectEqual(record.outcome, .text)
        TestSupport.expectEqual(record.steps.map(\.step), [.tapped, .captureRequested, .modelLoading, .firstAudio, .modelReady,
                                                            .stopped, .transcribed, .ended, .inserted])
        TestSupport.expectEqual(record.steps[4], .init(step: .modelReady, milliseconds: 1_900, footprintMB: 150, availableMB: 12))
        // A sample between steps moves the figures without adding a step, and says whether the least left changed.
        var noted = KeyboardDictationRecord(attemptID: attemptID, processID: processID, tappedAt: tappedAt, iosVersion: "27.0", warm: true)
        TestSupport.expect(noted.note(sample(30, available: 100)), "the first figure did not count as a change")
        TestSupport.expect(!noted.note(sample(35, peak: 60, available: 101)), "more memory left counted as a change")
        TestSupport.expect(noted.note(sample(20, peak: 50, available: 80)), "less memory left did not count as a change")
        TestSupport.expectEqual(noted.peakFootprintMB, 60)
        TestSupport.expectEqual(noted.leastAvailableMB, 80)
        TestSupport.expectEqual(noted.steps, [])
        // Unknown memory leaves the figures as they were.
        TestSupport.expect(!noted.note(KeyboardMemorySample()), "an unknown sample counted as a change")
        TestSupport.expectEqual(noted.peakFootprintMB, 60)
    }

    private static func testUnfiniteFiguresAreWrittenAsUnknown() {
        withStore { store in
            var record = KeyboardDictationRecord(attemptID: attemptID, processID: processID, tappedAt: tappedAt, iosVersion: "27.0", warm: false)
            record.reach(.tapped, milliseconds: .nan, memory: KeyboardMemorySample(footprintMB: .infinity, peakMB: .nan,
                                                                                    availableMB: -.infinity))
            record.audioSeconds = .nan
            record.stopToTextMilliseconds = .infinity
            try! store.writeKeyboardDictation(record)
            let read = store.readKeyboardDictation().value
            TestSupport.expectEqual(read?.steps, [.init(step: .tapped, milliseconds: nil, footprintMB: nil, availableMB: nil)])
            TestSupport.expect(read?.audioSeconds == nil && read?.stopToTextMilliseconds == nil && read?.peakFootprintMB == nil,
                               "a figure that is not finite was kept")
        }
    }

    private static func testUnfinishedMeansNoOutcomeFromAnotherProcess() {
        var record = KeyboardDictationRecord(attemptID: attemptID, processID: processID, tappedAt: tappedAt, iosVersion: "27.0", warm: false)
        record.reach(.tapped, milliseconds: 0, memory: sample(40, available: 100))
        record.reach(.modelLoading, milliseconds: 5, memory: sample(140, available: 2))
        TestSupport.expect(record.isUnfinished, "a running record is finished")
        TestSupport.expect(record.isUnfinished(byAnotherProcessThan: UUID()), "another process's running record is not unfinished")
        TestSupport.expect(!record.isUnfinished(byAnotherProcessThan: processID), "this process's own running record counts")
        record.processID = nil
        TestSupport.expect(!record.isUnfinished(byAnotherProcessThan: processID), "a record of an unknown process is another's")
        TestSupport.expect(!record.isUnfinished(byAnotherProcessThan: UUID()), "a record of an unknown process is another's")
        record.processID = processID
        // Any outcome finishes it, whatever the last step.
        for outcome in KeyboardDictationRecord.Outcome.allCases {
            var ended = record
            ended.outcome = outcome
            TestSupport.expect(!ended.isUnfinished(byAnotherProcessThan: UUID()), "\(outcome) left the record unfinished")
        }
    }

    private static func testAbandonedKeepsTheSteps() {
        withStore { store in
            var record = KeyboardDictationRecord(attemptID: attemptID, processID: processID, tappedAt: tappedAt, iosVersion: "27.0", warm: false)
            record.reach(.tapped, milliseconds: 0, memory: sample(40, available: 100))
            record.reach(.modelLoading, milliseconds: 5, memory: sample(140, available: 2))
            try! store.writeKeyboardDictation(record)
            var found = store.readKeyboardDictation().value!
            found.markAbandoned()
            try! store.writeKeyboardDictation(found)
            let rewritten = store.readKeyboardDictation().value
            TestSupport.expectEqual(rewritten?.outcome, .abandoned)
            TestSupport.expectEqual(rewritten?.attemptID, attemptID)
            TestSupport.expectEqual(rewritten?.processID, processID)
            TestSupport.expectEqual(rewritten?.steps, record.steps)
            TestSupport.expectEqual(rewritten?.lastStep, .modelLoading)
            TestSupport.expectEqual(rewritten?.leastAvailableMB, 2)
        }
    }

    private static func testFailuresMapToOutcomesAndWords() {
        for failure in KeyboardDictationFailure.allCases {
            TestSupport.expectEqual(KeyboardDictationRecord.Outcome(failure).failure, failure)
        }
        TestSupport.expectEqual(KeyboardDictationFailure.captureLost.shownError, .interrupted)
        TestSupport.expectEqual(KeyboardDictationFailure.modelFailed.shownError, .modelFailed)
        TestSupport.expectEqual(KeyboardDictationFailure.transcriptionFailed.shownError, .transcriptionFailed)
        for silent in [KeyboardDictationFailure.captureUnavailable, .startupTimeout, .keyboardDismissed, .hostTookOver] {
            TestSupport.expectEqual(silent.shownError, nil)
        }
        TestSupport.expectEqual(Set(KeyboardDictationFailure.allCases.filter(\.fallsBackToHost)), [.captureUnavailable, .startupTimeout])
        TestSupport.expectEqual(KeyboardDictationRecord.Outcome.cancelled.failure, nil)
        TestSupport.expectEqual(KeyboardDictationRecord.Outcome.noSpeech.failure, nil)
    }

    private static func stagingFile(_ name: String, in store: SharedDictationStore, modified: Date) -> URL {
        try! FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let url = store.directory.appendingPathComponent(name, isDirectory: false)
        try! Data("{}".utf8).write(to: url)
        try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The record's staging files are `.staging-kd-<UUID>.tmp`; the host's launch sweep (any age) leaves them while
    /// it removes every other staging file.
    private static func testStagingFilesAreTaggedAndSurviveTheLaunchSweep() {
        withStore { store in
            let now = Date()
            let keyboard = stagingFile(".staging-kd-\(UUID().uuidString).tmp", in: store, modified: now - 5)
            let other = stagingFile(".staging-\(UUID().uuidString).tmp", in: store, modified: now - 5)
            store.purgeStagingFiles(olderThan: 0, now: now)
            TestSupport.expect(exists(keyboard), "the launch sweep removed the keyboard's staging file")
            TestSupport.expect(!exists(other), "the launch sweep left another staging file")
            // A write that fails before its rename leaves nothing; one that succeeds leaves only the record.
            SharedDictationStoreTests.withReadOnlyDirectory(of: store) {
                TestSupport.expect((try? store.writeKeyboardDictation(fullRecord())) == nil, "a write into a read-only directory succeeded")
            }
            try! store.writeKeyboardDictation(fullRecord())
            let names = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
            TestSupport.expectEqual(Set(names), ["keyboard-dictation.json", keyboard.lastPathComponent])
            TestSupport.expect(keyboard.lastPathComponent.hasPrefix(SharedDictationStore.stagingPrefix
                                                                    + SharedDictationStore.keyboardDictationStagingTag),
                               "the tag is not the staging prefix's")
        }
    }

    private static func testAgeSweepRemovesOldTaggedStagingFiles() {
        withStore { store in
            let now = Date()
            let fresh = stagingFile(".staging-kd-\(UUID().uuidString).tmp", in: store, modified: now - DictationProtocol.resultTTL + 5)
            let old = stagingFile(".staging-kd-\(UUID().uuidString).tmp", in: store, modified: now - DictationProtocol.resultTTL - 5)
            store.purgeExpiredResults(now: now)
            TestSupport.expect(exists(fresh), "the age sweep removed a fresh keyboard staging file")
            TestSupport.expect(!exists(old), "the age sweep left an old keyboard staging file")
            // The launch sweep leaves even an old one: the age sweep's to remove.
            let older = stagingFile(".staging-kd-\(UUID().uuidString).tmp", in: store, modified: now - DictationProtocol.resultTTL - 5)
            store.purgeStagingFiles(olderThan: 0, now: now)
            TestSupport.expect(exists(older), "the launch sweep removed an old keyboard staging file")
            TestSupport.expect(exists(fresh), "the launch sweep removed a fresh keyboard staging file")
            store.purgeExpiredResults(now: now)
            TestSupport.expect(!exists(older), "the age sweep left an old keyboard staging file")
        }
    }

    private static func started(_ attempt: UUID, process: UUID = processID) -> KeyboardDictationRecord {
        var record = KeyboardDictationRecord(attemptID: attempt, processID: process, tappedAt: tappedAt, iosVersion: "27.0",
                                             warm: false)
        record.reach(.tapped, milliseconds: 0, memory: sample(40, available: 100))
        return record
    }

    /// Only the tap starts a record; a later write replaces it only while it holds that attempt's id.
    private static func testLaterWritesReplaceOnlyTheirOwnAttempt() {
        withStore { store in
            var first = started(attemptID)
            // Nothing to replace: a later write never creates the record.
            TestSupport.expectEqual(store.replaceKeyboardDictation(first), .skipped)
            TestSupport.expectEqual(store.readKeyboardDictation(), .absent)
            try! store.writeKeyboardDictation(first)
            first.reach(.firstAudio, milliseconds: 300, memory: sample(42, available: 98))
            TestSupport.expectEqual(store.replaceKeyboardDictation(first), .written)
            TestSupport.expectEqual(store.readKeyboardDictation().value?.lastStep, .firstAudio)
            // A newer tap's record: the older attempt's late step leaves it alone.
            let second = started(UUID())
            try! store.writeKeyboardDictation(second)
            first.end(.cancelled, milliseconds: 400, memory: sample(42, available: 98))
            TestSupport.expectEqual(store.replaceKeyboardDictation(first), .skipped)
            TestSupport.expectEqual(store.readKeyboardDictation(), .value(second))
            // An unreadable record is not replaced either.
            try! Data("{".utf8).write(to: store.keyboardDictationURL)
            TestSupport.expectEqual(store.replaceKeyboardDictation(second), .skipped)
            // A record without an attempt id never replaces anything.
            try! store.writeKeyboardDictation(second)
            var anonymous = second
            anonymous.attemptID = nil
            TestSupport.expectEqual(store.replaceKeyboardDictation(anonymous), .skipped)
            TestSupport.expect(KeyboardDictationRecord.mayReplace(.value(second), forAttempt: second.attemptID!), "own record refused")
            TestSupport.expect(!KeyboardDictationRecord.mayReplace(.absent, forAttempt: second.attemptID!), "absent record replaced")
        }
    }

    /// Once another process marked it abandoned, no write for that attempt replaces it.
    private static func testAbandonedRecordStaysAbandoned() {
        withStore { store in
            let other = UUID()
            var running = started(attemptID, process: other)
            try! store.writeKeyboardDictation(running)
            TestSupport.expectEqual(store.abandonUnfinishedKeyboardDictation(notWrittenBy: processID), .found(rewritten: true))
            running.reach(.firstAudio, milliseconds: 300, memory: sample(42, available: 98))
            TestSupport.expectEqual(store.replaceKeyboardDictation(running), .skipped)
            running.end(.text, milliseconds: 900, memory: sample(42, available: 98))
            TestSupport.expectEqual(store.replaceKeyboardDictation(running), .skipped)
            let read = store.readKeyboardDictation().value
            TestSupport.expectEqual(read?.outcome, .abandoned)
            TestSupport.expectEqual(read?.steps.map(\.step), [.tapped])
            var abandoned = running
            abandoned.outcome = .abandoned
            TestSupport.expect(!KeyboardDictationRecord.mayReplace(.value(abandoned), forAttempt: attemptID), "abandoned replaced")
            // Finished now: it is not abandoned again.
            TestSupport.expectEqual(store.abandonUnfinishedKeyboardDictation(notWrittenBy: UUID()), .none)
        }
    }

    private static func testOnlyAnotherKnownProcessesUnfinishedRecordIsAbandoned() {
        withStore { store in
            TestSupport.expectEqual(store.abandonUnfinishedKeyboardDictation(notWrittenBy: processID), .none)
            // This process's own running record.
            try! store.writeKeyboardDictation(started(attemptID))
            TestSupport.expectEqual(store.abandonUnfinishedKeyboardDictation(notWrittenBy: processID), .none)
            TestSupport.expectEqual(store.readKeyboardDictation().value?.outcome, nil)
            // A record whose process is unknown.
            var unknown = started(attemptID)
            unknown.processID = nil
            try! store.writeKeyboardDictation(unknown)
            TestSupport.expectEqual(store.abandonUnfinishedKeyboardDictation(notWrittenBy: processID), .none)
            // Another process's finished record.
            var finished = started(attemptID, process: UUID())
            finished.end(.cancelled, milliseconds: 10, memory: sample(40, available: 100))
            try! store.writeKeyboardDictation(finished)
            TestSupport.expectEqual(store.abandonUnfinishedKeyboardDictation(notWrittenBy: processID), .none)
            TestSupport.expectEqual(store.readKeyboardDictation(), .value(finished))
            // Another process's unfinished one, whose rewrite fails: still reported as found.
            try! store.writeKeyboardDictation(started(attemptID, process: UUID()))
            SharedDictationStoreTests.withReadOnlyDirectory(of: store) {
                TestSupport.expectEqual(store.abandonUnfinishedKeyboardDictation(notWrittenBy: processID), .found(rewritten: false))
            }
            TestSupport.expectEqual(store.readKeyboardDictation().value?.outcome, nil)
        }
    }
}
