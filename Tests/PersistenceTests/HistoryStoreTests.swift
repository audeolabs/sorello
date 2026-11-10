import DictationCore
import Foundation
import Persistence
import Testing

/// The Run Log: entries and their audio in the directory it is given. Audio is a synthetic tone; text is invented.
@MainActor
@Suite struct HistoryStoreTests {
    /// The store's directory sits inside the test's own, so a write anywhere else would show up there.
    private func historyDirectory(in temporary: borrowing TemporaryDirectory) -> URL {
        temporary.url.appendingPathComponent("history", isDirectory: true)
    }

    private func tone(seconds: Double = 0.25, frequency: Double = 440) -> [Float] {
        (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 2 * .pi * frequency / 16_000) * 0.5) }
    }

    private func draft(_ number: Int, text: String? = nil, outcome: DictationOutcome = .inserted,
                       samples: [Float]? = nil) -> HistoryDraft {
        HistoryDraft(date: Date(timeIntervalSince1970: 1_800_000_000 + Double(number)),
                     heard: "Synthetic sentence \(number).", text: text ?? "Synthetic sentence \(number).",
                     outcome: outcome, samples: samples ?? tone(frequency: 200 + Double(number) * 10))
    }

    private func wavFiles(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".wav") }
    }

    // MARK: Saving

    @Test func anEntryRoundTripsWithItsAudio() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        let samples = tone(seconds: 0.5)
        await store.record(draft(1, outcome: .leftOnClipboard, samples: samples))

        let entry = try #require(store.entries.first)
        #expect(store.entries.count == 1)
        #expect(entry.heard == "Synthetic sentence 1.")
        #expect(entry.text == "Synthetic sentence 1.")
        #expect(entry.outcome == .leftOnClipboard)
        #expect(entry.date == Date(timeIntervalSince1970: 1_800_000_001))
        #expect(entry.duration == 0.5)
        let url = try #require(store.audioURL(for: entry.id))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)

        let read = try #require(await store.samples(for: entry.id))
        #expect(read.count == samples.count)
        #expect(zip(read, samples).allSatisfy { abs($0 - $1) <= 0.5 / 32_767 + 1e-7 })

        let reopened = HistoryStore(directory: directory) { true }
        await reopened.load()
        #expect(reopened.entries == store.entries)
    }

    /// A dictation that was only "press enter" posted Return and inserted nothing; it is still a dictation.
    @Test func anEntryWithNoTextIsKept() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        await store.record(HistoryDraft(date: Date(timeIntervalSince1970: 1_800_000_000), heard: "Press enter.",
                                        text: "", outcome: .inserted, samples: tone()))
        await store.record(HistoryDraft(date: Date(timeIntervalSince1970: 1_800_000_001), heard: "", text: "",
                                        outcome: .transcriptionFailed, samples: tone()))
        let reopened = HistoryStore(directory: directory) { true }
        await reopened.load()
        #expect(reopened.entries.map(\.heard) == ["", "Press enter."])
        #expect(reopened.entries.map(\.text) == ["", ""])
        #expect(wavFiles(in: directory).count == 2)
    }

    @Test func newestComesFirst() async throws {
        let temporary = try TemporaryDirectory()
        let store = HistoryStore(directory: historyDirectory(in: temporary)) { true }
        for number in 1...3 { await store.record(draft(number)) }
        #expect(store.entries.map(\.heard) == (1...3).reversed().map { "Synthetic sentence \($0)." })
    }

    @Test func nothingIsRecordedWhileTheLogIsOff() async throws {
        let temporary = try TemporaryDirectory()
        let setting = KeepRunLog()
        let store = HistoryStore(directory: historyDirectory(in: temporary)) { setting.isOn }
        await store.record(draft(1))
        #expect(store.entries.isEmpty)
        #expect(temporary.contents().isEmpty)
        setting.isOn = true
        await store.record(draft(2))
        #expect(store.entries.count == 1)
    }

    @Test func entriesAreInRecordingOrderWhicheverSaveFinishesFirst() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        // The older recording is much longer, so its conversion finishes after the newer one's.
        let older = draft(1, samples: tone(seconds: 60))
        let newer = draft(2, samples: tone(seconds: 0.1))
        let first = Task { await store.record(older) }
        let second = Task { await store.record(newer) }
        await first.value
        await second.value
        #expect(store.entries.map(\.heard) == ["Synthetic sentence 2.", "Synthetic sentence 1."])

        await store.record(draft(0))
        #expect(store.entries.map(\.heard).last == "Synthetic sentence 0.", "an older recording goes below")
    }

    // MARK: The cap

    @Test func aTwentyFirstEntryEvictsTheOldestAndItsAudio() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        for number in 1...20 { await store.record(draft(number)) }
        let oldest = try #require(store.entries.last)
        let oldestAudio = try #require(store.audioURL(for: oldest.id))
        #expect(FileManager.default.fileExists(atPath: oldestAudio.path))

        await store.record(draft(21))
        #expect(store.entries.count == HistoryStore.capacity)
        #expect(store.entries.first?.heard == "Synthetic sentence 21.")
        #expect(!store.entries.contains { $0.id == oldest.id })
        #expect(!FileManager.default.fileExists(atPath: oldestAudio.path), "evicted audio is really gone")
        #expect(store.audioURL(for: oldest.id) == nil)
        #expect(wavFiles(in: directory).count == 20)
    }

    @Test func aRecordingOlderThanAFullLogIsNotKept() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        for number in 11...30 { await store.record(draft(number)) }
        let before = store.entries
        await store.record(draft(1))
        #expect(store.entries == before)
        #expect(wavFiles(in: directory).count == 20, "its audio is not left behind")
    }

    @Test func concurrentSavesAllLandAndRespectTheCap() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        await withTaskGroup { group in
            for number in 1...30 {
                let draft = draft(number)
                group.addTask { await store.record(draft) }
            }
        }
        #expect(store.entries.map(\.heard) == (11...30).reversed().map { "Synthetic sentence \($0)." },
                "the twenty newest recordings are kept, newest first")
        let named = Set(try store.entries.map { try #require(store.audioURL(for: $0.id)).lastPathComponent })
        #expect(Set(wavFiles(in: directory)) == named)

        let reopened = HistoryStore(directory: directory) { true }
        await reopened.load()
        #expect(reopened.entries == store.entries)
    }

    // MARK: Delete, replace, clear

    @Test func deleteRemovesOneEntryAndItsAudio() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        for number in 1...3 { await store.record(draft(number)) }
        let doomed = store.entries[1]
        let audio = try #require(store.audioURL(for: doomed.id))
        await store.delete(id: doomed.id)
        #expect(store.entries.map(\.heard) == ["Synthetic sentence 3.", "Synthetic sentence 1."])
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(await store.samples(for: doomed.id) == nil)

        let reopened = HistoryStore(directory: directory) { true }
        await reopened.load()
        #expect(reopened.entries == store.entries)
    }

    @Test func aRetryReplacesTheTextAndOutcomeOnly() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        await store.record(draft(1, text: "", outcome: .transcriptionFailed))
        await store.record(draft(2))
        let failed = store.entries[1]
        let samplesBefore = await store.samples(for: failed.id)

        await store.replace(id: failed.id, heard: "Synthetic retried.", text: "Synthetic retried",
                            outcome: .inserted)
        let retried = store.entries[1]
        #expect(retried.id == failed.id)
        #expect(retried.heard == "Synthetic retried.")
        #expect(retried.text == "Synthetic retried")
        #expect(retried.outcome == .inserted)
        #expect(retried.date == failed.date)
        #expect(retried.duration == failed.duration)
        #expect(await store.samples(for: failed.id) == samplesBefore)

        await store.replace(id: UUID(), heard: "x", text: "x", outcome: .inserted)
        let reopened = HistoryStore(directory: directory) { true }
        await reopened.load()
        #expect(reopened.entries == store.entries)
    }

    @Test func clearRemovesEverything() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        for number in 1...3 { await store.record(draft(number)) }
        let id = try #require(store.entries.first?.id)
        try Data("synthetic leftover".utf8).write(to: directory.appendingPathComponent(".index.json.leftover.tmp"))

        await store.clear()
        #expect(store.entries.isEmpty)
        #expect(store.audioURL(for: id) == nil)
        #expect(await store.samples(for: id) == nil)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty)

        await store.record(draft(4))
        #expect(store.entries.map(\.heard) == ["Synthetic sentence 4."], "a save after a clear is kept")
    }

    @Test func aClearThatCannotDeleteSaysSoAndShowsWhatIsLeft() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        for number in 1...2 { await store.record(draft(number)) }
        let recorded = store.entries
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        #expect(await store.clear() == false)
        #expect(store.entries == recorded, "the log does not claim to be empty")
        let reopened = HistoryStore(directory: directory) { true }
        await reopened.load()
        #expect(reopened.entries == recorded)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #expect(await store.clear())
        #expect(store.entries.isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty)
    }

    @Test func aClearInAFolderThatCannotBeListedKeepsShowingTheEntries() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        for number in 1...2 { await store.record(draft(number)) }
        let recorded = store.entries
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        #expect(await store.clear() == false)
        #expect(store.entries == recorded)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let reopened = HistoryStore(directory: directory) { true }
        await reopened.load()
        #expect(reopened.entries == recorded)
    }

    @Test func clearCancelsSavesThatBeganBeforeIt() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        // Each save begins (on the main actor, in order) before the clear does.
        let saves = (1...6).map { number in
            let draft = draft(number, samples: tone(seconds: 5))
            return Task { await store.record(draft) }
        }
        let clearing = Task { await store.clear() }
        for save in saves { await save.value }
        #expect(await clearing.value)

        #expect(store.entries.isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty)
        let reopened = HistoryStore(directory: directory) { true }
        await reopened.load()
        #expect(reopened.entries.isEmpty)
    }

    // MARK: Damaged files

    @Test(arguments: [
        Data("not json".utf8),
        Data(#"{"version":1,"entries":[{"id":"#.utf8),
        Data(#"{"version":2,"entries":[]}"#.utf8),
        Data(),
    ])
    func anUnreadableIndexIsDeletedWithItsAudio(contents: Data) async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        await store.record(draft(1))
        await store.record(draft(2))
        try contents.write(to: directory.appendingPathComponent("index.json"))

        let reopened = HistoryStore(directory: directory) { true }
        await reopened.load()
        #expect(reopened.entries.isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty,
                "the index is deleted, not kept, and the audio it named goes with it")
        await reopened.record(draft(3))
        #expect(reopened.entries.count == 1)
    }

    @Test func anIndexThatCannotBeOpenedIsKeptForLater() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        await store.record(draft(1))
        let index = directory.appendingPathComponent("index.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: index.path)

        let blocked = HistoryStore(directory: directory) { true }
        await blocked.load()
        #expect(blocked.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: index.path), "a file that may be good is not deleted")
        #expect(wavFiles(in: directory).count == 1, "nor is the audio it names")

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        await blocked.load()
        #expect(blocked.entries == store.entries)
    }

    @Test func aRestoredFolderWithoutWritePermissionIsStillTidied() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let orphan = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).wav")
        try WAVAudio.encode(tone()).write(to: orphan)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: orphan.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        let store = HistoryStore(directory: directory) { true }
        await store.load()
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try permissions(of: directory) == 0o700)
    }

    @Test func orphanedAudioAndTemporaryFilesAreRemovedAtLaunch() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        await store.record(draft(1))
        let entry = try #require(store.entries.first)
        let kept = try #require(store.audioURL(for: entry.id))
        let orphan = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).wav")
        let leftover = directory.appendingPathComponent(".\(UUID().uuidString.lowercased()).wav.0000.tmp")
        try WAVAudio.encode(tone()).write(to: orphan)
        try Data("partial".utf8).write(to: leftover)

        let reopened = HistoryStore(directory: directory) { true }
        await reopened.load()
        #expect(reopened.entries == store.entries)
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test func anEntryWhoseAudioIsGoneIsDropped() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        await store.record(draft(1))
        await store.record(draft(2))
        let lost = store.entries[0]
        try FileManager.default.removeItem(at: try #require(store.audioURL(for: lost.id)))

        let reopened = HistoryStore(directory: directory) { true }
        await reopened.load()
        #expect(reopened.entries == [store.entries[1]])
    }

    @Test func truncatedAudioReadsAsNothing() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        await store.record(draft(1))
        let entry = try #require(store.entries.first)
        let url = try #require(store.audioURL(for: entry.id))
        try Data(try Data(contentsOf: url).prefix(100)).write(to: url)
        #expect(await store.samples(for: entry.id) == nil)
    }

    // MARK: Where and how it writes

    @Test func writesOnlyInsideItsDirectoryReadableByTheUserOnly() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        await store.load()
        for number in 1...22 { await store.record(draft(number)) }
        await store.replace(id: store.entries[0].id, heard: "x", text: "x", outcome: .inserted)
        await store.delete(id: store.entries[1].id)

        #expect(temporary.contents().allSatisfy { $0 == "history" || $0.hasPrefix("history/") })
        #expect(try permissions(of: directory) == 0o700)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.count == 20) // 19 entries and the index
        for name in names {
            #expect(try permissions(of: directory.appendingPathComponent(name)) == 0o600, "\(name)")
        }
    }

    @Test func aRestoredLogOpenToOthersIsClosedWhenRead() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        let store = HistoryStore(directory: directory) { true }
        await store.record(draft(1))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in names {
            try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                  ofItemAtPath: directory.appendingPathComponent(name).path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

        let reopened = HistoryStore(directory: directory) { true }
        await reopened.load()
        #expect(reopened.entries.count == 1)
        #expect(try permissions(of: directory) == 0o700)
        for name in names {
            #expect(try permissions(of: directory.appendingPathComponent(name)) == 0o600, "\(name)")
        }
    }

    @Test func aDirectoryOpenToOthersIsClosedOnFirstWrite() async throws {
        let temporary = try TemporaryDirectory()
        let directory = historyDirectory(in: temporary)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let store = HistoryStore(directory: directory) { true }
        await store.record(draft(1))
        #expect(try permissions(of: directory) == 0o700)
    }
}

/// Stands in for the "Keep Run Log" setting.
@MainActor
private final class KeepRunLog {
    var isOn = false
}
