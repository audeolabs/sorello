import CoreGraphics
import DictationCore
import Foundation
import MacPlatform
import Persistence
import ScreenNotes
import SorelloUI
import SpeechEngine
import Synchronization
import Testing
@testable import SorelloApp

// Screen notes through the composition (ARCHITECTURE.md, section 14), with fakes for every part of the Mac they use:
// nothing records the screen, reads the pointer, draws over the screen or writes the pasteboard. The narration is
// invented.

struct DeniedMicrophone: MicrophoneAuthorizing {
    func current() -> MicrophoneAccess { .denied }
    func request() async -> MicrophoneAccess { .denied }
}

/// Screen Recording, as the test says it is.
final class FakeScreenPermission: ScreenPermissionChecking {
    private struct State {
        var granted = true
        var grantsOnRequest = false
        var requests = 0
        var openedSettings = 0
    }

    private let state = Mutex(State())
    var granted: Bool {
        get { state.withLock { $0.granted } }
        set { state.withLock { $0.granted = newValue } }
    }
    var grantsOnRequest: Bool {
        get { state.withLock { $0.grantsOnRequest } }
        set { state.withLock { $0.grantsOnRequest = newValue } }
    }
    var requests: Int { state.withLock { $0.requests } }
    var openedSettings: Int { state.withLock { $0.openedSettings } }

    var isGranted: Bool { granted }

    func request() -> Bool {
        state.withLock {
            $0.requests += 1
            if $0.grantsOnRequest { $0.granted = true }
            return $0.granted
        }
    }

    func openSettings() { state.withLock { $0.openedSettings += 1 } }
}

/// A recording that writes nothing, finishing and cancelling when told.
final class FakeRecording: NoteRecordingSession {
    private struct State {
        var finishes = 0
        var cancels = 0
        var interrupted: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())
    let startedAt: TimeInterval?
    /// The movie does not close cleanly, as when the stream stopped by itself.
    let finishFails: Bool
    var finishes: Int { state.withLock { $0.finishes } }
    var cancels: Int { state.withLock { $0.cancels } }

    init(startedAt: TimeInterval, finishFails: Bool = false) {
        self.startedAt = startedAt
        self.finishFails = finishFails
    }

    func onInterrupted(_ handler: @escaping @Sendable () -> Void) { state.withLock { $0.interrupted = handler } }
    func finish() async throws(ScreenRecordingFailure) {
        state.withLock { $0.finishes += 1 }
        if finishFails { throw .failed }
    }
    func cancel() async { state.withLock { $0.cancels += 1 } }
    /// As the stream stopping by itself.
    func interrupt() { state.withLock { $0.interrupted }?() }
}

/// Starts fake recordings and remembers what it was asked.
final class FakeRecorder: NoteRecorderStarting {
    struct Start: Equatable {
        var display: NoteDisplay
        var file: URL
        var narrate: Bool
        var microphone: String?
    }

    private struct State {
        var starts: [Start] = []
        var recordings: [FakeRecording] = []
        var fails = false
        var finishFails = false
        var holds = false
        var held: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    let clock: ManualClock
    var starts: [Start] { state.withLock { $0.starts } }
    var last: FakeRecording? { state.withLock { $0.recordings.last } }
    var fails: Bool {
        get { state.withLock { $0.fails } }
        set { state.withLock { $0.fails = newValue } }
    }
    var finishFails: Bool {
        get { state.withLock { $0.finishFails } }
        set { state.withLock { $0.finishFails = newValue } }
    }
    /// Starting waits for `release()`, as a slow ScreenCaptureKit start does.
    func hold() { state.withLock { $0.holds = true } }
    var waiting: Int { state.withLock { $0.held.count } }

    func release() {
        let held = state.withLock { state in
            state.holds = false
            defer { state.held = [] }
            return state.held
        }
        for waiter in held { waiter.resume() }
    }

    init(clock: ManualClock) { self.clock = clock }

    func startRecording(display: NoteDisplay, file: URL, narrate: Bool, microphone: String?)
        async throws(ScreenRecordingFailure) -> any NoteRecordingSession {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state -> Bool in
                guard state.holds else { return true }
                state.held.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
        let recording = FakeRecording(startedAt: clock.now, finishFails: finishFails)
        let fails = state.withLock { state in
            state.starts.append(Start(display: display, file: file, narrate: narrate, microphone: microphone))
            if !state.fails { state.recordings.append(recording) }
            return state.fails
        }
        if fails { throw .notPermitted }
        return recording
    }
}

@MainActor
final class FakePointer: PointerWatching {
    private(set) var handler: (@MainActor (PointerEvent) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0

    func start(display: NoteDisplay, startedAt: TimeInterval, handler: @escaping @MainActor (PointerEvent) -> Void) {
        starts += 1
        self.handler = handler
    }

    func stop() {
        stops += 1
        handler = nil
    }

    func send(_ event: PointerEvent) { handler?(event) }
}

@MainActor
final class FakeInk: InkPresenting {
    private(set) var shownOn: [CGRect] = []
    private(set) var scenes: [InkScene] = []
    private(set) var hides = 0

    func show(on frame: CGRect) { shownOn.append(frame) }
    func update(_ scene: InkScene) { scenes.append(scene) }
    func hide() { hides += 1 }
}

/// Says the movie is ten seconds of 1600 × 1000 with sound, and writes empty images where the real renderer would.
final class FakeRenderer: NoteRendering {
    private struct State {
        var rendered: [ScreenNote] = []
        var fails = false
        var hasAudio = true
        var holds = false
        var held: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    var rendered: [ScreenNote] { state.withLock { $0.rendered } }
    var fails: Bool {
        get { state.withLock { $0.fails } }
        set { state.withLock { $0.fails = newValue } }
    }
    var hasAudio: Bool {
        get { state.withLock { $0.hasAudio } }
        set { state.withLock { $0.hasAudio = newValue } }
    }

    func inspect(_ movie: URL) async throws(NoteRenderingFailure) -> NoteMovie {
        NoteMovie(duration: 10, size: CGSize(width: 1600, height: 1000), hasAudio: hasAudio)
    }

    /// Rendering waits for `release()`.
    func hold() { state.withLock { $0.holds = true } }

    func release() {
        let waiting = state.withLock { state in
            state.holds = false
            defer { state.held = [] }
            return state.held
        }
        for waiter in waiting { waiter.resume() }
    }

    func render(_ note: ScreenNote, movie: URL, folder: URL) async throws(NoteRenderingFailure) {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state -> Bool in
                guard state.holds else { return true }
                state.held.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
        if fails { throw .unreadable }
        state.withLock { $0.rendered.append(note) }
        let frames = folder.appendingPathComponent(ScreenNote.Files.frames, isDirectory: true)
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for keyframe in note.keyframes {
            FileManager.default.createFile(atPath: frames.appendingPathComponent(Keyframe.fileName(keyframe.number)).path,
                                           contents: Data())
        }
        FileManager.default.createFile(atPath: folder.appendingPathComponent(ScreenNote.Files.contactSheet).path,
                                       contents: Data())
    }
}

/// The fakes together, as a `ScreenNotePlatform`.
@MainActor
final class NoteFakes {
    let permission = FakeScreenPermission()
    let recorder: FakeRecorder
    let pointer = FakePointer()
    let ink = FakeInk()
    let renderer = FakeRenderer()
    var copied: [(summary: String, sheet: URL)] = []
    var revealed: [URL] = []
    static let display = NoteDisplay(id: 7, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)

    init(clock: ManualClock) { recorder = FakeRecorder(clock: clock) }

    var platform: ScreenNotePlatform {
        let ink = self.ink
        return ScreenNotePlatform(
            permission: permission, displayUnderPointer: { Self.display }, recorder: recorder, pointer: pointer,
            ink: { _ in ink }, renderer: renderer,
            copy: { [weak self] summary, sheet in self?.copied.append((summary, sheet)) },
            reveal: { [weak self] in self?.revealed.append($0) })
    }
}

@MainActor
struct ScreenNoteTests {
    @MainActor
    final class Fixture {
        let directory: URL
        let suite: TemporaryDefaults
        let clock: ManualClock
        let notes: NoteFakes
        let harness: Harness

        init(on: Bool = true, microphone: any MicrophoneAuthorizing = GrantedMicrophone()) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
            suite = try TemporaryDefaults()
            let harnessClock = ManualClock()
            clock = harnessClock
            notes = NoteFakes(clock: harnessClock)
            harness = Harness(directory: directory, defaults: suite.defaults, microphone: microphone,
                              screenNotes: notes.platform, clock: harnessClock)
            harness.app.settings.screenNotes = on
            harness.app.start()
        }

        isolated deinit { try? FileManager.default.removeItem(at: directory) }

        var app: AppComposition { harness.app }
        var coordinator: ScreenNoteCoordinator { harness.app.notes! }
        var store: ScreenNoteStore { ScreenNoteStore(directory: app.paths.screenNotesDirectory) }

        @discardableResult
        func press() -> Bool { app.relay.handle(.screenNotePressed, at: clock.now) }

        /// Presses the shortcut and waits until the note records.
        func startNote() async {
            press()
            await eventually { coordinator.phase == .recording }
        }

        /// Presses the shortcut again, past the guard, and waits for the note to be made or fail.
        func finishNote() async {
            clock.advance(by: 1)
            press()
            await eventually { coordinator.phase == .idle }
        }
    }

    // MARK: - Turning them on

    @Test func offByDefaultTheShortcutIsNotGivenToTheMonitorAndDoesNothing() async throws {
        let fixture = try Fixture(on: false)
        #expect(fixture.app.settings.shortcutBindings[.screenNote] == nil)
        #expect(fixture.harness.shortcuts.bindings.last?[.screenNote] == nil)
        #expect(!fixture.press())
        #expect(fixture.notes.recorder.starts.isEmpty)
        #expect(fixture.notes.permission.requests == 0)
    }

    @Test func turnedOnTheShortcutReachesTheMonitor() async throws {
        let fixture = try Fixture(on: false)
        fixture.app.settings.screenNotes = true
        await eventually { fixture.harness.shortcuts.bindings.last?[.screenNote] == .screenNote }
    }

    @Test func turningTheSwitchOnAsksForTheScreenOnceAndOnlyThen() async throws {
        let fixture = try Fixture(on: false)
        fixture.notes.permission.granted = false
        fixture.notes.permission.grantsOnRequest = true
        #expect(fixture.notes.permission.requests == 0, "launch asks nothing")
        fixture.harness.windows.setToggle(.screenNotes, true)
        #expect(fixture.app.settings.screenNotes)
        #expect(fixture.notes.permission.requests == 1)
        #expect(fixture.app.live.screenRecordingGranted)
        fixture.harness.windows.setToggle(.screenNotes, false)
        fixture.harness.windows.setToggle(.screenNotes, true)
        #expect(fixture.notes.permission.requests == 1, "granted, so not asked again")
    }

    @Test func turningTheSwitchOffThrowsAwayTheNoteRecording() async throws {
        let fixture = try Fixture()
        await fixture.startNote()
        let folder = try #require(fixture.notes.recorder.starts.first?.file.deletingLastPathComponent())
        fixture.harness.windows.setToggle(.screenNotes, false)
        #expect(fixture.coordinator.phase == .idle)
        await eventually { fixture.notes.recorder.last?.cancels == 1 }
        await eventually { !FileManager.default.fileExists(atPath: folder.path) }
        #expect(fixture.notes.copied.isEmpty)
    }

    @Test func quittingStopsTheRecordingAndDeletesTheNoteBeforeItReturns() async throws {
        let fixture = try Fixture()
        await fixture.startNote()
        let folder = try #require(fixture.notes.recorder.starts.first?.file.deletingLastPathComponent())
        await fixture.app.shutdown(limit: 3)
        #expect(fixture.notes.recorder.last?.cancels == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func turningOnLeavesAShortcutAnotherActionAlreadyHad() async throws {
        let fixture = try Fixture(on: false)
        fixture.app.settings.tapToToggleShortcut = .screenNote
        fixture.harness.windows.setToggle(.screenNotes, true)
        #expect(fixture.app.settings.tapToToggleShortcut == .screenNote)
        #expect(fixture.app.settings.screenNoteShortcut == nil)
    }

    @Test func quittingStopsTheNoteEvenWhileAnInsertionHoldsTheQuit() async throws {
        let fixture = try Fixture()
        await fixture.startNote()
        let folder = try #require(fixture.notes.recorder.starts.first?.file.deletingLastPathComponent())
        fixture.harness.inserter.neverIdle = true
        let quit = Task { await fixture.app.shutdown(limit: 3) }
        await eventually { fixture.notes.recorder.last?.cancels == 1 }
        await eventually { !FileManager.default.fileExists(atPath: folder.path) }
        await eventually {
            fixture.clock.advance(by: 3)
            return true
        }
        await quit.value
    }

    @Test func quittingWhileANoteIsMadeWaitsForIt() async throws {
        let fixture = try Fixture()
        fixture.notes.renderer.hold()
        await fixture.startNote()
        fixture.clock.advance(by: 1)
        fixture.press()
        #expect(fixture.coordinator.phase == .building)
        let quit = Task { await fixture.app.shutdown(limit: 30) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fixture.store.latest() == nil, "the note is still being made")
        fixture.notes.renderer.release()
        await quit.value
        #expect(fixture.store.latest() != nil, "and it finished before the quit returned")
    }

    @Test func theCopyWaitsForAnInsertionHoldingTheClipboard() async throws {
        let fixture = try Fixture()
        fixture.harness.inserter.holdClipboard()
        await fixture.startNote()
        fixture.clock.advance(by: 1)
        fixture.press()
        await eventually { fixture.store.latest() != nil }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fixture.notes.copied.isEmpty, "not while a dictation's paste holds the clipboard")
        fixture.harness.inserter.releaseClipboard()
        await eventually { fixture.notes.copied.count == 1 }
        #expect(fixture.harness.inserter.clipboardWrites == 1)
    }

    @Test func whileOffItsShortcutStillCannotBeGivenToAnotherAction() async throws {
        let fixture = try Fixture(on: false)
        fixture.harness.windows.record(.holdToTalk)
        await eventually { fixture.harness.shortcuts.isRecording }
        fixture.harness.shortcuts.press(.screenNote)
        await eventually { fixture.app.live.refusals[.holdToTalk] == .alreadyUsed(by: .screenNote) }
        #expect(fixture.app.settings.holdToTalkShortcut == .function)
    }

    @Test func withoutThePermissionAPressRecordsNothingAndOffersSettings() async throws {
        let fixture = try Fixture()
        fixture.notes.permission.granted = false
        fixture.press()
        #expect(fixture.notes.recorder.starts.isEmpty)
        #expect(fixture.notes.permission.requests == 0, "a press never asks")
        let notice = try #require(fixture.coordinator.notice)
        #expect(notice.text == "Screen notes need Screen Recording permission")
        #expect(notice.tone == .error)
        fixture.coordinator.noticeAction(notice.actions[0].id)
        #expect(fixture.notes.permission.openedSettings == 1)
        await eventually {
            fixture.clock.advance(by: ScreenNoteCoordinator.resultLinger)
            return fixture.coordinator.notice == nil
        }
    }

    // MARK: - Recording

    @Test func aPressRecordsTheDisplayUnderThePointerWithTheMicrophone() async throws {
        let fixture = try Fixture()
        await fixture.startNote()
        let start = try #require(fixture.notes.recorder.starts.first)
        #expect(start.display == NoteFakes.display)
        #expect(start.narrate)
        #expect(start.file.lastPathComponent == ScreenNote.Files.recording)
        #expect(start.file.deletingLastPathComponent().deletingLastPathComponent().path
            == fixture.app.paths.screenNotesDirectory.path)
        #expect(fixture.notes.ink.shownOn == [NoteFakes.display.frame])
        #expect(fixture.notes.pointer.starts == 1)
        let notice = try #require(fixture.coordinator.notice)
        #expect(notice.text == "Recording screen note")
        #expect(notice.actions.map(\.title) == ["Finish", "Cancel"])
        await eventually { fixture.harness.pill.current == .notice(notice) }
    }

    @Test func withoutMicrophoneAccessTheNoteHasNoNarration() async throws {
        let fixture = try Fixture(microphone: DeniedMicrophone())
        await eventually { fixture.app.runtime.state.microphone == .denied }
        await fixture.startNote()
        #expect(fixture.notes.recorder.starts.last?.narrate == false)
        await fixture.finishNote()
        #expect(fixture.notes.renderer.rendered.last?.narration == .noMicrophone)
        #expect(fixture.notes.copied.last?.summary.contains("- Narration: none") == true)
    }

    @Test func aSecondPressTooSoonIsIgnored() async throws {
        let fixture = try Fixture()
        await fixture.startNote()
        fixture.clock.advance(by: 0.2)
        #expect(!fixture.press())
        #expect(fixture.coordinator.phase == .recording)
    }

    @Test func shiftDrawsInkWhichUndoTakesBack() async throws {
        let fixture = try Fixture()
        await fixture.startNote()
        let pointer = fixture.notes.pointer
        pointer.send(.moved(CGPoint(x: 100, y: 100), time: 1, shift: true))
        pointer.send(.moved(CGPoint(x: 200, y: 100), time: 1.1, shift: true))
        #expect(fixture.notes.ink.scenes.last?.lines.count == 1)
        #expect(fixture.notes.ink.scenes.last?.lines.first?.endedAt == nil)
        pointer.send(.moved(CGPoint(x: 200, y: 100), time: 1.2, shift: false))
        #expect(fixture.notes.ink.scenes.last?.lines.first?.endedAt == 1.2, "a stroke ends when ⇧ is released")
        #expect(fixture.app.relay.handle(.undoPressed, at: fixture.clock.now), "⌘Z is taken while a note records")
        #expect(fixture.notes.ink.scenes.last?.lines.isEmpty == true)
        await fixture.finishNote()
        #expect(fixture.notes.renderer.rendered.last?.marks.strokes.isEmpty == true)
        #expect(!fixture.app.relay.handle(.undoPressed, at: fixture.clock.now), "and left alone otherwise")
    }

    @Test func escapeTheSessionDidNotWantCancelsTheNote() async throws {
        let fixture = try Fixture()
        await fixture.startNote()
        let folder = try #require(fixture.notes.recorder.starts.first?.file.deletingLastPathComponent())
        #expect(fixture.app.relay.handle(.cancelPressed, at: fixture.clock.now))
        #expect(fixture.coordinator.phase == .idle)
        #expect(fixture.coordinator.notice == nil)
        #expect(fixture.notes.ink.hides >= 1)
        #expect(fixture.notes.pointer.stops >= 1)
        await eventually { fixture.notes.recorder.last?.cancels == 1 }
        await eventually { !FileManager.default.fileExists(atPath: folder.path) }
        #expect(fixture.notes.copied.isEmpty)
        #expect(!fixture.app.relay.handle(.cancelPressed, at: fixture.clock.now))
    }

    @Test func escapeCancelsADictationBeforeANote() async throws {
        let fixture = try Fixture()
        await fixture.startNote()
        fixture.app.relay.handle(.togglePressed, at: fixture.clock.now)
        await eventually { if case .recording = fixture.app.runtime.state.capture { true } else { false } }
        #expect(fixture.app.relay.handle(.cancelPressed, at: fixture.clock.now))
        #expect(fixture.coordinator.phase == .recording, "the session took Escape")
        #expect(fixture.app.runtime.state.capture == .idle)
    }

    @Test func theShortcutNeverReachesTheSession() async throws {
        let fixture = try Fixture()
        fixture.app.relay.handle(.holdPressed, at: fixture.clock.now)
        fixture.app.relay.handle(.holdReleased(.keyUp), at: fixture.clock.now + 0.1)
        let before = fixture.app.runtime.state
        fixture.app.relay.handle(.screenNotePressed, at: fixture.clock.now + 0.2)
        fixture.app.relay.handle(.undoPressed, at: fixture.clock.now + 0.2)
        #expect(fixture.app.runtime.state.tap == before.tap, "the double tap's arm is untouched")
    }

    @Test func aNoteInProgressShowsOverASuggestionButNotOverTheSession() {
        func notice(_ id: UInt64) -> PillDisplay.Notice {
            PillDisplay.Notice(id: id, symbol: "s", tone: .information, text: "\(id)", actions: [])
        }
        let dictation = PillDisplay.waiting(.transcribing)
        let suggestion = notice(1), note = notice(2)
        #expect(AppComposition.pill(session: dictation, suggestion: suggestion, note: note, noteInProgress: true)
            == (dictation, true))
        #expect(AppComposition.pill(session: nil, suggestion: suggestion, note: note, noteInProgress: true)
            == (.notice(note), true), "recording withdraws the suggestion")
        #expect(AppComposition.pill(session: nil, suggestion: suggestion, note: note, noteInProgress: false)
            == (.notice(suggestion), false), "a note's result waits behind a suggestion")
        #expect(AppComposition.pill(session: nil, suggestion: nil, note: note, noteInProgress: false)
            == (.notice(note), false))
        #expect(AppComposition.pill(session: nil, suggestion: nil, note: nil, noteInProgress: false) == (.hidden, false))
    }

    // MARK: - The note

    @Test func finishingMakesTheNoteAndCopiesIt() async throws {
        let fixture = try Fixture()
        fixture.harness.speech.timedWords = .success([TimedWord(text: "This", time: 2),
                                                      TimedWord(text: "breaks.", time: 2.4)])
        await fixture.startNote()
        let pointer = fixture.notes.pointer
        pointer.send(.buttonDown(CGPoint(x: 720, y: 450), time: 3, shift: false))
        pointer.send(.buttonUp(CGPoint(x: 720, y: 450), time: 3.1))
        pointer.send(.buttonDown(CGPoint(x: 360, y: 225), time: 5, shift: true))
        pointer.send(.buttonUp(CGPoint(x: 360, y: 225), time: 5.1))
        await fixture.finishNote()

        let folder = try #require(fixture.store.latest())
        let note = try #require(fixture.notes.renderer.rendered.last)
        #expect(note.narration == .transcribed)
        #expect(note.words.map(\.text) == ["This", "breaks."])
        #expect(note.marks.clicks == [Click(time: 3, x: 0.5, y: 0.5)])
        #expect(note.marks.pins == [Pin(number: 1, time: 5, x: 0.25, y: 0.25)])
        #expect(note.duration == 10)
        #expect(note.frameSize == CGSize(width: 1600, height: 1000))
        #expect(note.display == CGSize(width: 1440, height: 900))

        let summary = try String(contentsOf: folder.appendingPathComponent(ScreenNote.Files.summary), encoding: .utf8)
        #expect(summary.contains("- Folder: \(folder.path)"))
        #expect(summary.contains("> 0:02 This breaks."))
        #expect(summary.contains("pin 1 at (400, 250)"))
        let manifest = try Data(contentsOf: folder.appendingPathComponent(ScreenNote.Files.manifest))
        #expect(try JSONDecoder().decode(NoteManifest.self, from: manifest).pins.count == 1)

        let copied = try #require(fixture.notes.copied.last)
        #expect(copied.summary == summary)
        #expect(copied.sheet.path == folder.appendingPathComponent(ScreenNote.Files.contactSheet).path)
        let notice = try #require(fixture.coordinator.notice)
        #expect(notice.text == "Screen note copied")
        fixture.coordinator.noticeAction(notice.actions[0].id)
        #expect(fixture.notes.revealed.map(\.path) == [folder.path])
        await eventually {
            fixture.clock.advance(by: ScreenNoteCoordinator.resultLinger)
            return fixture.coordinator.notice == nil
        }
    }

    @Test func finishOnThePillFinishesTheNote() async throws {
        let fixture = try Fixture()
        await fixture.startNote()
        let finish = try #require(fixture.coordinator.notice?.actions.first)
        fixture.harness.pill.onNoticeAction(try #require(fixture.coordinator.notice?.id), finish.id)
        await eventually { fixture.coordinator.phase == .idle }
        #expect(fixture.notes.recorder.last?.finishes == 1)
        #expect(fixture.store.latest() != nil)
    }

    @Test func aRecordingThatStopsByItselfFinishesTheNote() async throws {
        let fixture = try Fixture()
        await fixture.startNote()
        fixture.notes.recorder.last?.interrupt()
        await eventually { fixture.store.latest() != nil }
    }

    @Test func aMovieThatDidNotCloseCleanlyIsStillMadeIntoANote() async throws {
        let fixture = try Fixture()
        fixture.notes.recorder.finishFails = true
        await fixture.startNote()
        fixture.notes.recorder.last?.interrupt()
        await eventually { fixture.coordinator.phase == .idle }
        #expect(fixture.store.latest() != nil)
        #expect(fixture.notes.copied.count == 1)
    }

    @Test func cancellingWhileTheRecordingStartsStopsItWhenItArrivesAndLeavesNothing() async throws {
        let fixture = try Fixture()
        fixture.notes.recorder.hold()
        fixture.press()
        await eventually { fixture.notes.recorder.waiting == 1 }
        #expect(fixture.coordinator.phase == .starting)
        #expect(fixture.app.relay.handle(.cancelPressed, at: fixture.clock.now))
        #expect(fixture.coordinator.phase == .idle)
        fixture.notes.recorder.release()
        await eventually { fixture.notes.recorder.last?.cancels == 1 }
        let notes = fixture.app.paths.screenNotesDirectory.path
        await eventually { ((try? FileManager.default.contentsOfDirectory(atPath: notes)) ?? []).isEmpty }
        #expect(fixture.notes.ink.shownOn.isEmpty, "it never showed as recording")
        #expect(fixture.coordinator.notice == nil)
    }

    @Test func tenMinutesFinishTheNote() async throws {
        let fixture = try Fixture()
        await fixture.startNote()
        await eventually {
            fixture.clock.advance(by: ScreenNoteCoordinator.limit)
            return fixture.store.latest() != nil
        }
    }

    @Test func withoutTheModelTheNoteSaysWhyThereIsNoTranscript() async throws {
        let fixture = try Fixture()
        fixture.harness.speech.timedWords = .failure(.engineUnavailable(.modelMissing))
        await fixture.startNote()
        await fixture.finishNote()
        #expect(fixture.notes.renderer.rendered.last?.narration == .notTranscribed("the speech model is not downloaded"))
        #expect(fixture.notes.copied.count == 1)
    }

    @Test func aNoteThatCannotBeMadeLeavesNothing() async throws {
        let fixture = try Fixture()
        fixture.notes.renderer.fails = true
        await fixture.startNote()
        await fixture.finishNote()
        #expect(fixture.store.notes().isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.app.paths.screenNotesDirectory.path)
        #expect(leftovers.isEmpty)
        #expect(fixture.notes.copied.isEmpty)
        #expect(fixture.coordinator.notice?.text == "Couldn’t make the screen note")
    }

    @Test func aRecordingThatCannotStartLeavesNothing() async throws {
        let fixture = try Fixture()
        fixture.notes.recorder.fails = true
        fixture.press()
        await eventually { fixture.coordinator.phase == .idle }
        #expect(fixture.coordinator.notice?.text == "Couldn’t record the screen")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.app.paths.screenNotesDirectory.path)
        #expect(leftovers.isEmpty)
    }

    @Test func atLaunchANoteThatNeverFinishedIsDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenNoteStore(directory: AppPaths(root: directory).screenNotesDirectory)
        let unfinished = try store.makeFolder(startedAt: Date())
        let suite = try TemporaryDefaults()
        let clock = ManualClock()
        let harness = Harness(directory: directory, defaults: suite.defaults, screenNotes: NoteFakes(clock: clock).platform,
                              clock: clock)
        harness.app.start()
        #expect(!FileManager.default.fileExists(atPath: unfinished.path))
    }
}
