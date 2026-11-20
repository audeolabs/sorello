import DictationCore
import Foundation
import MacPlatform
import Observation
import Persistence
import ScreenNotes
import SorelloUI
import SpeechEngine

/// Screen notes' one state machine (ARCHITECTURE.md, section 14): idle, starting, recording, building. It takes the
/// Screen Note shortcut, ⌘Z and an Escape the session did not want, records through the platform, tracks the marks,
/// and builds the note when it finishes. What it shows goes to the pill as the app's own notice, `notice`.
@MainActor
@Observable
final class ScreenNoteCoordinator {
    /// A press this soon after the start is ignored, so a double press does not make an empty note.
    static let finishGuard: TimeInterval = 0.4
    /// A note this long finishes by itself.
    static let limit: TimeInterval = 10 * 60
    /// How long the pill says a note was copied, or why one could not be made.
    static let resultLinger: TimeInterval = 4

    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case building
    }

    /// The notice's actions.
    enum Action {
        static let finish = "screenNote.finish"
        static let cancel = "screenNote.cancel"
        static let show = "screenNote.show"
        static let openSettings = "screenNote.openSettings"
    }

    /// What the pill shows for screen notes, when the session shows nothing.
    private(set) var notice: PillDisplay.Notice?
    private(set) var phase: Phase = .idle
    /// The last note made, for Show.
    private(set) var lastNote: URL?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let store: ScreenNoteStore
    @ObservationIgnored private let platform: ScreenNotePlatform
    @ObservationIgnored private let clock: any SessionClock
    @ObservationIgnored private let words: @Sendable (URL) async throws(FileSpeechFailure) -> [TimedWord]
    @ObservationIgnored private let microphone: @MainActor () -> (narrate: Bool, deviceID: String?)
    @ObservationIgnored private let clipboard: any ClipboardTurns
    /// Making the note, which quitting lets finish.
    @ObservationIgnored private var building: Task<Void, Never>?
    @ObservationIgnored private var ids = NoteNoticeID()

    /// The note in progress.
    @ObservationIgnored private var current: Current?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// Stopping and deleting a cancelled note, which quitting waits for.
    @ObservationIgnored private var cleanup: Task<Void, Never>?

    private final class Current {
        /// Made by the starting task, off the event tap; there once the note records.
        var folder: URL?
        let display: NoteDisplay
        let startedAt: Date
        let pressedAt: TimeInterval
        let narrate: Bool
        var recording: (any NoteRecordingSession)?
        /// Starting the recording, cancelled with the note.
        var starting: Task<Void, Never>?
        var tracker: InkTracker
        var ink: (any InkPresenting)?
        var zero: TimeInterval = 0
        var limit: Task<Void, Never>?
        var cancelled = false

        init(display: NoteDisplay, startedAt: Date, pressedAt: TimeInterval, narrate: Bool) {
            self.display = display
            self.startedAt = startedAt
            self.pressedAt = pressedAt
            self.narrate = narrate
            tracker = InkTracker(display: display.frame.size)
        }
    }

    /// - `words`: the narration's words with their times (`SpeechEngine.transcribeWords(file:)`).
    /// - `microphone`: whether the microphone may be used now, and the device a dictation would record from.
    /// - `clipboard`: the inserter's turns, so the note's copy never lands in the middle of a dictation's paste.
    init(settings: SettingsStore, store: ScreenNoteStore, platform: ScreenNotePlatform, clock: any SessionClock,
         words: @escaping @Sendable (URL) async throws(FileSpeechFailure) -> [TimedWord],
         microphone: @escaping @MainActor () -> (narrate: Bool, deviceID: String?),
         clipboard: any ClipboardTurns) {
        self.clipboard = clipboard
        self.settings = settings
        self.store = store
        self.platform = platform
        self.clock = clock
        self.words = words
        self.microphone = microphone
    }

    /// At launch: a note that never finished is deleted.
    func start() {
        store.removeUnfinished()
    }

    /// Whether `id` is one of this coordinator's notices.
    func owns(_ id: UInt64) -> Bool { NoteNoticeID.owns(id) }

    // MARK: - Triggers

    /// The Screen Note shortcut: starts a note, or finishes the one recording. Returns whether it did something.
    @discardableResult
    func pressed(at time: TimeInterval) -> Bool {
        guard settings.screenNotes else { return false }
        switch phase {
        case .idle:
            begin(at: time)
            return true
        case .recording:
            guard let current, time - current.pressedAt >= Self.finishGuard else { return false }
            finish()
            return true
        case .starting, .building:
            return false
        }
    }

    /// ⌘Z: undoes the last mark while a note records. Returns true while one records, so ⌘Z goes nowhere else then.
    func undo() -> Bool {
        guard phase == .recording, let current else { return false }
        current.tracker.undo()
        showInk()
        return true
    }

    /// Escape the session did not want, or Cancel on the pill: throws the note away. Returns whether there was one.
    @discardableResult
    func cancel() -> Bool {
        guard phase == .starting || phase == .recording, let current else { return false }
        current.cancelled = true
        current.starting?.cancel()
        current.limit?.cancel()
        platform.pointer.stop()
        current.ink?.hide()
        let recording = current.recording, store = self.store, starting = current.starting
        let previous = cleanup
        cleanup = Task {
            await previous?.value
            // A recording still starting stops itself, and deletes what it wrote, before this deletes the folder.
            await starting?.value
            await recording?.cancel()
            if let folder = current.folder { store.delete(folder) }
        }
        self.current = nil
        phase = .idle
        show(nil)
        Diagnostics.record("screenNote.cancelled")
        return true
    }

    /// Quitting: a note still recording is thrown away, and this returns once its recording has stopped and its
    /// folder is gone. A note being made is waited for, so it finishes if the quit gives it time.
    func quitting() async {
        cancel()
        await cleanup?.value
        await building?.value
    }

    /// A notice's action was clicked.
    func noticeAction(_ action: String) {
        switch action {
        case Action.finish: if phase == .recording { finish() }
        case Action.cancel: cancel()
        case Action.show: if let lastNote { platform.reveal(lastNote) }
        case Action.openSettings: platform.permission.openSettings()
        default: break
        }
    }

    // MARK: - Recording

    private func begin(at time: TimeInterval) {
        guard platform.permission.isGranted else {
            show(text: String(localized: "Screen notes need Screen Recording permission"), symbol: "rectangle.dashed",
                 tone: .error, actions: [.init(id: Action.openSettings, title: String(localized: "Open Settings"),
                                               isPrimary: true)],
                 linger: Self.resultLinger)
            return
        }
        guard let display = platform.displayUnderPointer() else { return }
        let started = Date()
        let mic = microphone()
        let current = Current(display: display, startedAt: started, pressedAt: time, narrate: mic.narrate)
        self.current = current
        phase = .starting
        let recorder = platform.recorder, store = self.store
        // Everything that touches the disk or the screen happens here, after the key's event has been handled.
        current.starting = Task {
            let folder: URL
            do {
                folder = try await Task.detached { try store.makeFolder(startedAt: started) }.value
            } catch {
                guard !current.cancelled else { return }
                self.current = nil
                phase = .idle
                failed()
                return
            }
            current.folder = folder
            guard !current.cancelled else { return }
            let recording: any NoteRecordingSession
            do {
                recording = try await recorder.startRecording(
                    display: display, file: folder.appendingPathComponent(ScreenNote.Files.recording),
                    narrate: mic.narrate, microphone: mic.deviceID)
            } catch {
                guard !current.cancelled else { return }
                store.delete(folder)
                self.current = nil
                phase = .idle
                failed(String(localized: "Couldn’t record the screen"))
                return
            }
            guard !current.cancelled else {
                // Cancelled while it started: the recording that arrived late is stopped, and what it wrote goes.
                await recording.cancel()
                store.delete(folder)
                return
            }
            recorded(recording, for: current)
        }
    }

    private func recorded(_ recording: any NoteRecordingSession, for current: Current) {
        current.recording = recording
        current.zero = recording.startedAt ?? clock.now
        phase = .recording
        let zero = current.zero, clock = self.clock
        let ink = platform.ink { clock.now - zero }
        ink.show(on: current.display.frame)
        current.ink = ink
        platform.pointer.start(display: current.display, startedAt: zero) { [weak self, weak current] event in
            guard let self, let current, self.current === current else { return }
            switch event {
            case .moved(let point, let time, let shift): current.tracker.pointer(at: point, time: time, shift: shift)
            case .buttonDown(let point, let time, let shift): current.tracker.buttonDown(at: point, time: time, shift: shift)
            case .buttonUp(let point, let time): current.tracker.buttonUp(at: point, time: time)
            }
            self.showInk()
        }
        let token = ObjectIdentifier(current)
        recording.onInterrupted { [weak self] in
            Task { @MainActor in
                guard let self, self.current.map(ObjectIdentifier.init) == token, self.phase == .recording else { return }
                self.finish()
            }
        }
        current.limit = Task { [weak self] in
            do { try await clock.sleep(for: Self.limit) } catch { return }
            guard let self, self.current === current, self.phase == .recording else { return }
            self.finish()
        }
        show(text: String(localized: "Recording screen note"), symbol: "record.circle", tone: .information,
             actions: [.init(id: Action.finish, title: String(localized: "Finish"), isPrimary: true),
                       .init(id: Action.cancel, title: String(localized: "Cancel"))])
        Diagnostics.record("screenNote.started")
    }

    /// The overlay's scene from the marks so far, in points of the display.
    private func showInk() {
        guard let current, let ink = current.ink else { return }
        let size = current.display.frame.size
        func point(_ p: TimedPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
        var lines = current.tracker.strokes.map { InkScene.Line(points: $0.points.map(point), endedAt: $0.end) }
        if let drawing = current.tracker.current { lines.append(InkScene.Line(points: drawing.map(point), endedAt: nil)) }
        let pins = current.tracker.pins.map {
            InkScene.Pin(number: $0.number, point: point(TimedPoint(t: $0.time, x: $0.x, y: $0.y)), droppedAt: $0.time)
        }
        ink.update(InkScene(lines: lines, pins: pins))
    }

    // MARK: - Building

    private func finish() {
        guard phase == .recording, let current, let recording = current.recording else { return }
        current.limit?.cancel()
        platform.pointer.stop()
        current.ink?.hide()
        let marks = current.tracker.finish()
        phase = .building
        show(text: String(localized: "Making screen note…"), symbol: "rectangle.stack", tone: .information, actions: [])
        let platform = self.platform, store = self.store, words = self.words, clipboard = self.clipboard
        building = Task {
            defer { building = nil }
            do {
                let folder = try await Self.build(current, recording: recording, marks: marks, platform: platform,
                                                  words: words, clipboard: clipboard)
                store.prune()
                lastNote = folder
                self.current = nil
                phase = .idle
                show(text: String(localized: "Screen note copied"), symbol: "doc.on.clipboard.fill", tone: .information,
                     actions: [.init(id: Action.show, title: String(localized: "Show"))], linger: Self.resultLinger)
                Diagnostics.record("screenNote.made")
            } catch {
                if let folder = current.folder { store.delete(folder) }
                self.current = nil
                phase = .idle
                failed()
            }
        }
    }

    /// Finishes the movie and makes the note in its folder: the narration, the keyframes, the images, the summary and
    /// the manifest, then the clipboard (ARCHITECTURE.md, section 14, "The note").
    private static func build(_ current: Current, recording: any NoteRecordingSession, marks: NoteMarks,
                              platform: ScreenNotePlatform,
                              words: @Sendable (URL) async throws(FileSpeechFailure) -> [TimedWord],
                              clipboard: any ClipboardTurns) async throws -> URL {
        try await recording.finish()
        guard let folder = current.folder else { throw ScreenRecordingFailure.failed }
        let movieFile = folder.appendingPathComponent(ScreenNote.Files.recording)
        let movie = try await platform.renderer.inspect(movieFile)
        var heard: [NoteWord] = []
        let narration: Narration
        if !current.narrate {
            narration = .noMicrophone
        } else if !movie.hasAudio {
            narration = .notTranscribed(String(localized: "no sound was recorded"))
        } else {
            do {
                heard = try await words(movieFile).map { NoteWord(time: $0.time, text: $0.text) }
                narration = .transcribed
            } catch {
                narration = .notTranscribed(reason(error))
            }
        }
        let note = ScreenNote(startedAt: current.startedAt, duration: movie.duration, display: current.display.frame.size,
                              frameSize: movie.size, marks: marks, words: heard, narration: narration)
        try await platform.renderer.render(note, movie: movieFile, folder: folder)
        let date = DateFormatter.localizedString(from: current.startedAt, dateStyle: .medium, timeStyle: .short)
        let summary = note.summary(folder: folder.path, date: date)
        try Data(summary.utf8).write(to: folder.appendingPathComponent(ScreenNote.Files.summary), options: .atomic)
        // Written last: a folder with a manifest is a finished note.
        try note.manifest().write(to: folder.appendingPathComponent(ScreenNote.Files.manifest), options: .atomic)
        // Between insertions: a dictation's text on the clipboard is pasted, and put back, before this replaces it.
        if await clipboard.beginClipboardWrite() {
            platform.copy(summary, folder.appendingPathComponent(ScreenNote.Files.contactSheet))
            await clipboard.endClipboardWrite()
        }
        return folder
    }

    /// Why the narration was not transcribed, in the summary's words.
    private static func reason(_ failure: FileSpeechFailure) -> String {
        switch failure {
        case .engineUnavailable(.modelMissing): String(localized: "the speech model is not downloaded")
        case .engineUnavailable: String(localized: "the speech model could not be loaded")
        case .cannotOpen, .unreadable: String(localized: "the sound could not be read")
        case .failed, .cancelled: String(localized: "the transcription failed")
        }
    }

    // MARK: - The pill

    private func failed(_ text: String = String(localized: "Couldn’t make the screen note")) {
        show(text: text, symbol: "exclamationmark.triangle.fill", tone: .error, actions: [], linger: Self.resultLinger)
        Diagnostics.record("screenNote.failed")
    }

    private func show(text: String, symbol: String, tone: PillDisplay.Notice.Tone, actions: [PillDisplay.Notice.Action],
                      linger: TimeInterval? = nil) {
        show(PillDisplay.Notice(id: ids.make(), symbol: symbol, tone: tone, text: text, actions: actions), linger: linger)
    }

    private func show(_ notice: PillDisplay.Notice?, linger: TimeInterval? = nil) {
        expiry?.cancel()
        expiry = nil
        self.notice = notice
        guard let notice, let linger else { return }
        let clock = self.clock
        expiry = Task { [weak self] in
            do { try await clock.sleep(for: linger) } catch { return }
            guard let self, self.notice?.id == notice.id else { return }
            self.notice = nil
        }
    }
}

/// Ids for screen notes' notices: in the app's range (`AppNoticeID`), with a bit of their own, so they are never
/// another notice's.
nonisolated struct NoteNoticeID {
    static let base: UInt64 = AppNoticeID.base | (1 << 62)
    private var next: UInt64 = 0

    mutating func make() -> UInt64 {
        next += 1
        return Self.base | next
    }

    static func owns(_ id: UInt64) -> Bool { id & base == base }
}
