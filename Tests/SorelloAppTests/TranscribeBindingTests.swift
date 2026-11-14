import FileTranscription
import Foundation
import SorelloUI
import Synchronization
import Testing
import TextRules
@testable import SorelloApp

/// A transcriber the test drives: each call waits until the test reports progress and finishes it, and records the
/// file and the rules it was given. Cancelling the calling task ends the call at once with `cancelled`, as the real
/// one does.
final class FakeFiles: FileTranscribing {
    /// One call to `transcribe`.
    final class Call: Sendable {
        let file: URL
        let rules: TextRuleOptions?
        private let progress: @Sendable (FileTranscriptionProgress) -> Void
        private struct State {
            var waiting: CheckedContinuation<Result<String, FileTranscriptionFailure>, Never>?
            var outcome: Result<String, FileTranscriptionFailure>?
            var cancelled = false
        }
        private let state = Mutex(State())

        init(file: URL, rules: TextRuleOptions?, progress: @escaping @Sendable (FileTranscriptionProgress) -> Void) {
            self.file = file
            self.rules = rules
            self.progress = progress
        }

        var wasCancelled: Bool { state.withLock { $0.cancelled } }

        /// Reports `progress` as the real transcriber would, from whatever thread the test is on.
        func report(_ progress: FileTranscriptionProgress) { self.progress(progress) }

        /// Ends the call with `outcome`, unless it has already ended.
        func finish(_ outcome: Result<String, FileTranscriptionFailure>) {
            let waiting = state.withLock { state -> CheckedContinuation<Result<String, FileTranscriptionFailure>, Never>? in
                guard state.outcome == nil else { return nil }
                state.outcome = outcome
                defer { state.waiting = nil }
                return state.waiting
            }
            waiting?.resume(returning: outcome)
        }

        func cancel() {
            state.withLock { $0.cancelled = true }
            finish(.failure(.cancelled))
        }

        func wait() async -> Result<String, FileTranscriptionFailure> {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Result<String, FileTranscriptionFailure>? in
                    if let outcome = state.outcome { return outcome }
                    state.waiting = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }

    private let calls = Mutex<[Call]>([])

    var all: [Call] { calls.withLock { $0 } }
    var last: Call? { all.last }

    func transcribe(_ file: URL, rules: TextRuleOptions?,
                    progress: @escaping @Sendable (FileTranscriptionProgress) -> Void)
        async throws(FileTranscriptionFailure) -> String {
        let call = Call(file: file, rules: rules, progress: progress)
        calls.withLock { $0.append(call) }
        let outcome = await withTaskCancellationHandler {
            await call.wait()
        } onCancel: {
            call.cancel()
        }
        return try outcome.get()
    }
}

/// What the window asked of the rest of the app.
@MainActor
final class TranscribeLog {
    var shown = 0
    var pickers: [@MainActor (URL) -> Void] = []
    var saved: [(text: String, name: String)] = []
    var copied: [String] = []
    var generalOpened = 0
    let prepared = Mutex(0)

    var ports: TranscribePorts {
        TranscribePorts(
            show: { [unowned self] in shown += 1 },
            chooseFile: { [unowned self] in pickers.append($0) },
            save: { [unowned self] in saved.append(($0, $1)) },
            copy: { [unowned self] in copied.append($0) },
            openGeneral: { [unowned self] in generalOpened += 1 },
            prepareModel: { [self] in prepared.withLock { $0 += 1 } })
    }
}

/// ARCHITECTURE.md, section 5, "Transcribing a file", and section 8, "Windows", Transcribe File: the window's model,
/// driven through the actions its view reports, over a transcriber the test controls.
@MainActor
@Suite struct TranscribeBindingTests {
    let files = FakeFiles()
    let log = TranscribeLog()
    /// The rules the app would read now; a test changes them to see when they are read.
    let rules = RulesBox()
    let binding: TranscribeBinding
    let talk = URL(fileURLWithPath: "/tmp/invented/harbour talk.m4a")
    let other = URL(fileURLWithPath: "/tmp/invented/other.wav")
    var states: [TranscribeState] { recorded.states }
    let recorded = StateLog()

    init() {
        let rules = self.rules, recorded = self.recorded
        binding = TranscribeBinding(appName: "Sorello Test", transcriber: files, rules: { rules.options },
                                    ports: log.ports)
        binding.stateChanged = { recorded.states.append($0) }
    }

    private var state: TranscribeState { binding.model.state }

    /// Opens the window as the menu's row does, and lets its picker go unanswered, as when the user drops a file
    /// instead.
    private func openWindow() {
        guard !binding.windowIsOpen else { return }
        binding.open()
    }

    /// Starts `file` as a drop on the open window does, and waits for the transcriber to be asked.
    @discardableResult
    private func drop(_ file: URL) async throws -> FakeFiles.Call {
        openWindow()
        let before = files.all.count
        binding.model.actions.dropFile(file)
        await eventually { files.all.count > before }
        return try #require(files.last)
    }

    // MARK: A file, start to end

    @Test func aDroppedFileIsTranscribedAndItsTextShown() async throws {
        let call = try await drop(talk)
        #expect(call.file == talk)
        #expect(state == .transcribing(file: "harbour talk.m4a", read: 0, length: 0))
        call.report(.transcribing(read: 4, length: 9))
        await eventually { state == .transcribing(file: "harbour talk.m4a", read: 4, length: 9) }
        call.report(.transcribing(read: 9, length: 9))
        call.finish(.success("Meet at the north gate at 9."))
        await eventually { state == .done(file: "harbour talk.m4a", text: "Meet at the north gate at 9.") }
        #expect(states.last == state)
    }

    @Test func preparingTheModelIsShownUntilTheFileIsRead() async throws {
        let call = try await drop(talk)
        call.report(.preparingModel)
        await eventually { state == .preparing(file: "harbour talk.m4a") }
        call.report(.transcribing(read: 0, length: 20))
        await eventually { state == .transcribing(file: "harbour talk.m4a", read: 0, length: 20) }
    }

    /// Progress reported from another thread reaches the window in the order it was reported.
    @Test func progressArrivesInOrder() async throws {
        let call = try await drop(talk)
        let reports = (1...200).map { FileTranscriptionProgress.transcribing(read: Double($0), length: 200) }
        await Task.detached { for report in reports { call.report(report) } }.value
        await eventually { state == .transcribing(file: "harbour talk.m4a", read: 200, length: 200) }
        let reads = states.compactMap { state -> Double? in
            if case .transcribing(_, let read, _) = state { read } else { nil }
        }
        #expect(reads == reads.sorted())
    }

    @Test(arguments: ["", "  \n "])
    func noWordsIsNoSpeechHeard(text: String) async throws {
        let call = try await drop(talk)
        call.finish(.success(text))
        await eventually { state == .nothingHeard(file: "harbour talk.m4a") }
    }

    @Test(arguments: [
        (FileTranscriptionFailure.cannotOpen, TranscribeFailure.cannotOpen),
        (.unreadable, .unreadable), (.modelMissing, .modelMissing), (.noModelForThisMac, .noModelForThisMac),
        (.modelUnavailable, .modelUnavailable), (.failed, .failed),
    ])
    func eachFailureIsShownWithItsReason(failure: FileTranscriptionFailure, reason: TranscribeFailure) async throws {
        let call = try await drop(talk)
        call.finish(.failure(failure))
        await eventually { state == .failed(file: "harbour talk.m4a", reason: reason) }
    }

    // MARK: Rules

    /// The rules are the ones the user has as the transcription starts; changing them meanwhile changes nothing for
    /// it, and the next transcription takes the new ones.
    @Test func theRulesAreReadWhenATranscriptionStarts() async throws {
        rules.options = TextRuleOptions(macros: [], pressEnterCommand: true, spokenNumbers: true,
                                        spokenDelimiters: true, promptTag: "[dictated]")
        let first = try await drop(talk)
        let atStart = rules.options
        rules.options = TextRuleOptions(macros: [VoiceMacro(command: "sign off", text: "Warm regards")],
                                        pressEnterCommand: false, spokenNumbers: false, spokenDelimiters: false,
                                        promptTag: "[dictated]")
        #expect(first.rules == atStart)
        first.finish(.success("Invented words."))
        await eventually { state.takesFiles }
        let second = try await drop(other)
        #expect(second.rules == rules.options)
    }

    // MARK: One file at a time

    @Test func aSecondFileIsNotTakenWhileOneIsUnderWay() async throws {
        let call = try await drop(talk)
        let shown = log.shown
        binding.model.actions.dropFile(other)
        binding.open(file: other)
        binding.take(other)
        try await Task.sleep(for: .milliseconds(50))
        #expect(files.all.count == 1 && !call.wasCancelled)
        #expect(state == .transcribing(file: "harbour talk.m4a", read: 0, length: 0))
        #expect(log.shown > shown, "The window comes forward instead")
    }

    @Test func aNewFileReplacesAFinishedOne() async throws {
        let call = try await drop(talk)
        call.finish(.success("Invented words."))
        await eventually { state.takesFiles }
        let next = try await drop(other)
        #expect(next.file == other)
        #expect(state == .transcribing(file: "other.wav", read: 0, length: 0))
    }

    // MARK: Cancel and close

    @Test func cancelStopsTheTranscriptionAndEmptiesTheWindow() async throws {
        let call = try await drop(talk)
        call.report(.transcribing(read: 3, length: 60))
        await eventually { state != .transcribing(file: "harbour talk.m4a", read: 0, length: 0) }
        binding.model.actions.cancel()
        #expect(state == .empty)
        await eventually { call.wasCancelled }
        // Whatever the transcriber still reports changes nothing.
        call.report(.transcribing(read: 9, length: 60))
        call.finish(.success("Too late."))
        try await Task.sleep(for: .milliseconds(50))
        #expect(state == .empty)
    }

    @Test func closingTheWindowCancelsAndForgetsTheText() async throws {
        let call = try await drop(talk)
        binding.windowClosed()
        #expect(state == .empty)
        await eventually { call.wasCancelled }

        let done = try await drop(other)
        done.finish(.success("Invented words."))
        await eventually { state == .done(file: "other.wav", text: "Invented words.") }
        binding.windowClosed()
        #expect(state == .empty)
        // Nothing is left to copy or save, and Try Again has no file.
        binding.model.actions.copy()
        binding.model.actions.save()
        binding.model.actions.tryAgain()
        #expect(log.copied.isEmpty && log.saved.isEmpty && files.all.count == 2)
    }

    // MARK: Remedies

    @Test func tryAgainTranscribesTheSameFileAgain() async throws {
        let call = try await drop(talk)
        call.finish(.failure(.failed))
        await eventually { state == .failed(file: "harbour talk.m4a", reason: .failed) }
        binding.model.actions.tryAgain()
        await eventually { files.all.count == 2 }
        #expect(files.last?.file == talk)
        #expect(log.prepared.withLock { $0 } == 0)
    }

    /// Retry asks the engine to prepare again, shows that it is preparing, and then transcribes the same file.
    @Test func retryPreparesTheModelThenTranscribesTheSameFile() async throws {
        let call = try await drop(talk)
        call.finish(.failure(.modelUnavailable))
        await eventually { state == .failed(file: "harbour talk.m4a", reason: .modelUnavailable) }
        binding.model.actions.retry()
        #expect(state == .preparing(file: "harbour talk.m4a"))
        await eventually { files.all.count == 2 }
        #expect(log.prepared.withLock { $0 } == 1)
        #expect(files.last?.file == talk)
    }

    @Test func downloadOpensGeneral() async throws {
        let call = try await drop(talk)
        call.finish(.failure(.modelMissing))
        await eventually { state == .failed(file: "harbour talk.m4a", reason: .modelMissing) }
        binding.model.actions.download()
        #expect(log.generalOpened == 1)
        #expect(files.all.count == 1)
    }

    // MARK: Copy and Save

    @Test func copyPutsTheTextOnTheClipboard() async throws {
        let call = try await drop(talk)
        call.finish(.success("Invented words, 23 of them."))
        await eventually { state.takesFiles }
        binding.model.actions.copy()
        #expect(log.copied == ["Invented words, 23 of them."])
    }

    @Test func saveOffersTheFilesNameAsATextFile() async throws {
        let call = try await drop(talk)
        call.finish(.success("Invented words."))
        await eventually { state.takesFiles }
        binding.model.actions.save()
        #expect(log.saved.map(\.text) == ["Invented words."])
        #expect(log.saved.map(\.name) == ["harbour talk.txt"])
    }

    @Test func theSavedNameReplacesTheExtension() {
        #expect(TranscribeBinding.textFileName(for: "talk.m4a") == "talk.txt")
        #expect(TranscribeBinding.textFileName(for: "a.b.mov") == "a.b.txt")
        #expect(TranscribeBinding.textFileName(for: "notes") == "notes.txt")
    }

    // MARK: Ways in

    /// The menu's row brings the window forward and shows the picker; a file chosen there is transcribed.
    @Test func theMenuRowShowsTheWindowAndThePicker() async throws {
        binding.open()
        #expect(log.shown == 1 && log.pickers.count == 1)
        let pick = try #require(log.pickers.first)
        pick(talk)
        await eventually { files.all.count == 1 }
        #expect(files.last?.file == talk)
    }

    /// While a file is being transcribed the menu's row only brings the window forward.
    @Test func theMenuRowShowsNoPickerWhileAFileIsUnderWay() async throws {
        try await drop(talk)
        let shown = log.shown, pickers = log.pickers.count
        binding.open()
        #expect(log.shown == shown + 1 && log.pickers.count == pickers)
    }

    /// A drop's file arrives a moment after the drop. If the window was closed meanwhile, or a picker's choice
    /// arrives after it closed, nothing is taken: no transcription runs without the window, and it holds no text.
    @Test func aFileArrivingAfterTheWindowClosedIsNotTaken() async throws {
        openWindow()
        let picker = try #require(log.pickers.last)
        binding.windowClosed()
        binding.model.actions.dropFile(talk)
        picker(other)
        try await Task.sleep(for: .milliseconds(50))
        #expect(files.all.isEmpty)
        #expect(state == .empty)

        // Opened again, the window takes files as before.
        binding.open()
        try await drop(talk)
    }

    @Test func chooseFileShowsThePickerAndTakesWhatIsChosen() async throws {
        let call = try await drop(talk)
        call.finish(.failure(.unreadable))
        await eventually { state.takesFiles }
        binding.model.actions.chooseFile()
        let pick = try #require(log.pickers.last)
        pick(other)
        await eventually { files.all.count == 2 }
        #expect(files.last?.file == other)
    }

    /// A file opened with Sorello from the Finder brings the window forward and is transcribed.
    @Test func aFileOpenedFromTheFinderIsTranscribed() async throws {
        binding.open(file: talk)
        #expect(log.shown >= 1)
        await eventually { files.all.count == 1 }
        #expect(files.last?.file == talk)
    }
}

/// The rules the test says the user has now.
@MainActor
final class RulesBox {
    var options = TextRuleOptions(macros: [], pressEnterCommand: false, spokenNumbers: true, spokenDelimiters: true,
                                  promptTag: "[dictated]")
}

/// Every state the window was given, in order.
@MainActor
final class StateLog {
    var states: [TranscribeState] = []
}
