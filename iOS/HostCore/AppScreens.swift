import Foundation

/// What the app's own screens show for a state, apart from layout (ARCHITECTURE.md, "Host app"): the session card's
/// state and its one accent, the speech model's state dot, the start-session screen's phase word and return cue, the
/// route it names, onboarding's microphone step and spoken progress, the idle countdown in words, when the background
/// cover hides the app, when the app's sheets close for the start-session screen, and the support addresses. The views
/// only draw these. Pure.

/// One of the brand colours a state may carry, on a small dot or glyph only (never a fill).
enum AppAccent: Equatable, Sendable {
    case aurora, glacier, coral, ember
}

/// The session card on Home, as the Live Activity's Lock Screen shows a session.
enum SessionCardState: Equatable, Sendable {
    /// No session: the mark and the Start pill.
    case off
    /// No session, and the microphone is off for Sorello: Open Settings is the only action.
    case microphoneOff
    case starting
    /// A session is waiting for the keyboard: the time left.
    case ready
    case listening
    case transcribing
    /// Stopped, and waiting for the model to finish preparing before transcribing.
    case preparing

    init(session: HostStatus.Session, permission: CapturePermission, sessionError: HostErrorCode?,
         dictation: DictationStatus.Phase?, dictationInProgress: Bool, model: HostStatus.Model) {
        switch session {
        case .inactive:
            // A denial the user has since lifted in Settings no longer blocks Start.
            let denied = permission == .denied || (permission != .granted && sessionError == .microphonePermissionDenied)
            self = denied ? .microphoneOff : .off
        case .starting:
            self = .starting
        case .active:
            switch (dictationInProgress ? dictation : nil) {
            case .starting?, .recording?: self = .listening
            case .transcribing?: self = model == .preparing ? .preparing : .transcribing
            default: self = .ready
            }
        }
    }

    /// The state in words, as the Live Activity names its phases; nil where the card shows only the Start pill.
    var title: String? {
        switch self {
        case .off: return nil
        case .microphoneOff: return "Microphone off"
        case .starting: return "Starting"
        case .ready: return "Ready to dictate"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .preparing: return "Preparing model"
        }
    }

    /// The mark's dot: aurora when ready (and on Start), coral while recording, glacier while waiting; nil where the
    /// card shows the microphone-off glyph instead, in ember.
    var accent: AppAccent? {
        switch self {
        case .off, .ready: return .aurora
        case .listening: return .coral
        case .starting, .transcribing, .preparing: return .glacier
        case .microphoneOff: return nil
        }
    }

    /// Whether the card keeps a line under its title even when there is nothing in it yet, so the card keeps its
    /// height from starting to ready. Microphone off has no line, and no session has no title.
    var reservesDetailLine: Bool {
        switch self {
        case .off, .microphoneOff: return false
        case .starting, .ready, .listening, .transcribing, .preparing: return true
        }
    }

    /// Whether the session is running, so the card offers End rather than Start.
    var isSessionOn: Bool {
        switch self {
        case .off, .microphoneOff, .starting: return false
        case .ready, .listening, .transcribing, .preparing: return true
        }
    }
}

/// The speech model's row on Home: "Speech model" and a state dot, or a check once it is ready, with its state in
/// words for VoiceOver.
enum ModelBadge {
    /// Ready is a check, so the state is a shape and not only a colour; nil: the state's dot.
    static func symbol(_ model: HostStatus.Model) -> String? {
        model == .ready ? "checkmark" : nil
    }

    /// Nil: a neutral grey dot (not prepared yet).
    static func accent(_ model: HostStatus.Model) -> AppAccent? {
        switch model {
        case .ready: return .aurora
        case .preparing: return .glacier
        case .failed, .unavailable: return .ember
        case .notPrepared: return nil
        }
    }

    static func spoken(_ model: HostStatus.Model) -> String {
        switch model {
        case .unavailable: return "Not included in this build"
        case .notPrepared: return "Not prepared yet"
        case .preparing: return "Preparing"
        case .ready: return "Ready"
        case .failed: return "Preparation failed"
        }
    }
}

/// The start-session screen (the bounce): its one word, the island's accent, and whether the return cue shows.
enum BouncePhase: Equatable, Sendable {
    case starting, listening, transcribing, done, cancelled, stopped

    init(_ phase: DictationStatus.Phase?) {
        switch phase {
        case .starting?, nil: self = .starting
        case .recording?: self = .listening
        case .transcribing?: self = .transcribing
        case .completed?: self = .done
        case .cancelled?: self = .cancelled
        case .failed?: self = .stopped
        }
    }

    var word: String {
        switch self {
        case .starting: return "Starting"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .done: return "Done"
        case .cancelled: return "Cancelled"
        case .stopped: return "Stopped"
        }
    }

    /// The island's accent: the recording dot, the wait's glint, or the mark's dot when it is over. Nil: a neutral
    /// dot, for a dictation the person cancelled themselves (ember is for one that failed).
    var accent: AppAccent? {
        switch self {
        case .starting, .transcribing: return .glacier
        case .listening: return .coral
        case .done: return .aurora
        case .cancelled: return nil
        case .stopped: return .ember
        }
    }

    /// Swiping back is the next step while the text is still on its way, and once it is ready.
    var showsReturnCue: Bool {
        switch self {
        case .listening, .transcribing, .done: return true
        case .starting, .cancelled, .stopped: return false
        }
    }
}

/// How the start-session screen shows the way back to the app that opened Sorello (an app cannot send the user
/// back; they swipe or tap the status bar's link).
enum SwipeBackCue: Equatable, Sendable {
    /// The status bar's "◀ App" link: an iPhone with a Home button has no swipe along the bottom edge.
    case statusBarLink
    /// The swipe right along the bottom edge.
    case bottomEdgeSwipe

    /// From the window's bottom safe-area inset, which only a Home-button iPhone has at zero.
    init(bottomSafeAreaInset: Double) {
        self = bottomSafeAreaInset > 0 ? .bottomEdgeSwipe : .statusBarLink
    }

    /// How many times the cue shows its motion before it rests: once, and never with Reduce Motion.
    static func demonstrations(reduceMotion: Bool) -> Int { reduceMotion ? 0 : 1 }

    var spoken: String {
        switch self {
        case .statusBarLink: return "Tap the back link at the top left to return to your app"
        case .bottomEdgeSwipe: return "Swipe right along the bottom edge to return to your app"
        }
    }
}

extension HeadphonesNotice {
    /// The route in two words beside its glyph, on the start-session screen.
    var shortLabel: String {
        switch self {
        case .iPhoneMicrophone: return "iPhone mic"
        case .headphonesMicrophone: return "Headphones mic"
        }
    }

    var symbol: String {
        switch self {
        case .iPhoneMicrophone: return "iphone"
        case .headphonesMicrophone: return "headphones"
        }
    }
}

/// The neutral surface over the app while it is in the background, so the snapshot iOS zooms on the way back (and the
/// app switcher's card) is the start-session screen's empty background, not Home: after the keyboard's Start, the
/// island arrives on it, with no Home in between.
enum BackgroundCover {
    enum Scene: Equatable, Sendable { case active, inactive, background }

    /// Whether the cover shows after a change of `scene` or of `bounceShown`, given whether it shows now (`covered`).
    /// Only the background raises it: iOS's own prompts and Control Center make the app inactive, which keeps what is
    /// on screen. Becoming active lowers it, unless the start-session screen is up over it; it then goes when that
    /// screen does, so Home is there underneath.
    static func covers(scene: Scene, bounceShown: Bool, covered: Bool) -> Bool {
        switch scene {
        case .background: return true
        case .inactive: return covered
        case .active: return covered && bounceShown
        }
    }
}

/// The app's sheets (Add word, Edit word, Find strength) when the keyboard's Start asks for the start-session screen.
/// SwiftUI can't show that screen over a sheet, so a sheet left open would hide it while the dictation records unseen.
/// The sheets close at once, without animation, when it is requested; its going changes nothing.
enum StartSessionSheets {
    /// Whether the app's sheets close after `bounceShown` changes from `bounceWasShown`.
    static func close(bounceWasShown: Bool, bounceShown: Bool) -> Bool {
        bounceShown && !bounceWasShown
    }
}

/// The session's idle countdown on Home, as VoiceOver reads it: one sentence rather than the glyph's words and the
/// timer ("Session ends in 4 minutes 56 seconds if idle").
enum SessionCountdown {
    static func spoken(secondsLeft: Int) -> String {
        let seconds = max(secondsLeft, 0)
        func count(_ value: Int, _ unit: String) -> String { "\(value) \(unit)\(value == 1 ? "" : "s")" }
        let minutes = seconds / 60, rest = seconds % 60
        let parts = [minutes > 0 ? count(minutes, "minute") : nil,
                     rest > 0 || minutes == 0 ? count(rest, "second") : nil].compactMap { $0 }
        return "Session ends in \(parts.joined(separator: " ")) if idle"
    }
}

/// Onboarding's microphone step. App Review (guideline 5.1.1(iv)) wants the pill before the system's permission prompt
/// to read as the next step, never as "Allow": the prompt itself asks.
enum OnboardingMicrophoneStep {
    static let title = "Microphone"

    /// The main pill: Continue (to the system prompt while the choice is open), or Open Settings once it is off.
    static func primaryButton(_ permission: CapturePermission) -> String {
        permission == .denied ? "Open Settings" : "Continue"
    }
}

/// Onboarding's progress, as VoiceOver reads it.
enum OnboardingProgress {
    /// "Step 2 of 4" for the second of four steps (`index` from 0).
    static func spoken(index: Int, count: Int) -> String {
        let count = max(count, 1)
        return "Step \(min(max(index, 0), count - 1) + 1) of \(count)"
    }
}

/// Where the app sends people for help and for its privacy policy (ARCHITECTURE.md, "Bug report"). Not stored names:
/// they follow the publisher, not the identifiers the app was first published with.
enum SupportContact {
    static let email = "support@audeolabs.com"
    static let privacyPolicy = URL(string: "https://audeolabs.github.io/sorello/privacy.html")!
}

// MARK: Notes (ARCHITECTURE.md, "Host app", Notes)

/// The Notes screen for the vault's state: what it offers, and whether any note shows.
enum NotesScreen: Equatable, Sendable {
    /// No vault, and the iPhone has no passcode: it says one is needed, and makes nothing.
    case needsPasscode
    /// No vault: a few words on what it is, and Make vault.
    case firstUse
    /// The vault was just made: the recovery code is offered, and may be skipped.
    case recoveryOffer
    /// Unlock and Record, and nothing of any note: no text, title, count or date.
    case locked
    /// The search field and the list.
    case unlocked
    /// Notes on this iPhone, but no secret: the recovery code, or erasing.
    case secretMissing

    init(vault: NoteVaultState, canMakeVault: Bool, offersRecoveryCode: Bool) {
        switch vault {
        case .noVault: self = canMakeVault ? .firstUse : .needsPasscode
        case .locked: self = .locked
        case .unlocked: self = offersRecoveryCode ? .recoveryOffer : .unlocked
        case .secretMissing: self = .secretMissing
        }
    }

    /// Whether any note shows: its text, its date, or how many there are.
    var showsNotes: Bool { self == .unlocked }

    /// Whether Record is offered: recording needs a vault, never an unlock.
    var offersRecord: Bool { self == .locked || self == .unlocked }

    var offersUnlock: Bool { self == .locked }
}

/// The Notes screens' sentences.
enum NotesWords {
    /// What the vault is, in a few words, before it is made.
    static let vault =
        "Notes keeps what you say as text, sealed on this iPhone. Only Face ID or your passcode opens it. Recording never needs either."
    static let locked = "Notes are locked. Recording a new note doesn’t need them open."
    static let passcodeNeeded = "Notes needs a passcode on this iPhone. Set one in Settings, then come back."
    static let recoveryOffer =
        "A recovery code opens your notes on a new iPhone. You can make one now or later in Notes settings."
    /// Under the recovery code's row in Notes settings.
    static let recoverySetting =
        "The only way back into your notes on a new iPhone. Making a new one stops the old one working."
    /// Shown with the recovery code itself, which shows once.
    static let recoveryWarning =
        "This code is the only way back into your notes on a new iPhone. Sorello can’t recover it for you. Write it down and keep it safe; it won’t be shown again."
    static let secretMissing =
        "Your notes are on this iPhone, but the key that opens them isn’t. Enter your recovery code to open them."
}

/// Record, or Stop while a note is in progress wherever it started, or Saving while it saves.
enum NoteRecordButton: Equatable, Sendable {
    case record, stop, saving

    /// Nil where the screen offers no Record and no note is in progress.
    init?(offersRecord: Bool, note phase: VoiceNoteStatus.Phase?) {
        switch phase {
        case .preparing?, .recording?: self = .stop
        case .saving?: self = .saving
        case nil:
            guard offersRecord else { return nil }
            self = .record
        }
    }

    var title: String {
        switch self {
        case .record: return "Record"
        case .stop: return "Stop"
        case .saving: return "Saving"
        }
    }

    var symbol: String {
        switch self {
        case .record: return "mic.fill"
        case .stop: return "stop.fill"
        case .saving: return "arrow.down.circle"
        }
    }

    /// The glyph's colour: coral while a note records, glacier while it saves.
    var accent: AppAccent? {
        switch self {
        case .record: return nil
        case .stop: return .coral
        case .saving: return .glacier
        }
    }

    var isEnabled: Bool { self != .saving }
}

/// The note screen's one mode: recording (the text read-only and live) or editing (an ordinary text field), never
/// both; locked, it shows no text.
enum NoteScreenMode: Equatable, Sendable {
    /// The vault is locked: Unlock, and Stop while this note is in progress.
    case locked(inProgress: Bool)
    /// This note waits for the model: nothing is recorded yet.
    case preparing
    case recording
    /// This note stopped and its last piece is being written: no Stop, no edits yet.
    case saving
    /// The text field, Resume and Delete; Resume waits while another note is in progress or saves.
    case editing(canResume: Bool)

    /// `recordingNoteID` is the session core's note, and `phase` its phase; nil when none.
    init(isUnlocked: Bool, noteID: UUID, recordingNoteID: UUID?, phase: VoiceNoteStatus.Phase?) {
        let isThisNote = phase != nil && recordingNoteID == noteID
        guard isUnlocked else {
            self = .locked(inProgress: isThisNote && phase != .saving)
            return
        }
        switch isThisNote ? phase : nil {
        case .preparing?: self = .preparing
        case .recording?: self = .recording
        case .saving?: self = .saving
        case nil: self = .editing(canResume: phase == nil)
        }
    }

    var showsText: Bool {
        if case .locked = self { return false }
        return true
    }

    /// The live, read-only text, as against the text field.
    var isLive: Bool { self == .preparing || self == .recording || self == .saving }

    var offersStop: Bool { self == .preparing || self == .recording || self == .locked(inProgress: true) }

    var isEditing: Bool {
        if case .editing = self { return true }
        return false
    }

    /// What the screen says of the recording, above its text; nil when it shows none.
    var status: String? {
        switch self {
        case .preparing: return "Preparing the speech model. Nothing is recorded yet."
        case .recording: return "Recording"
        case .saving: return "Saving"
        case .locked, .editing: return nil
        }
    }

    /// The status's dot: coral while recording, glacier while waiting.
    var accent: AppAccent? {
        switch self {
        case .recording: return .coral
        case .preparing, .saving: return .glacier
        case .locked, .editing: return nil
        }
    }
}

/// The note being recorded as it shows: the vault's text, with the provisional tail at the end of the recording run's
/// text. `before + after` is the vault's text; the tail is dimmed between them.
struct NoteLiveText: Equatable, Sendable {
    var before: String
    var provisional: String
    var after: String

    init(note: Note, provisional: String, format: NoteRunFormatter) {
        let runs = note.pendingRuns
        if let last = runs.last, last.isRecording {
            let base = NoteMerge.merge(runs.dropLast().map { NoteRunContent(place: $0.place, pieces: $0.pieces) },
                                       into: note.body, format: format)
            let index = NoteMerge.index(of: last.place, in: base)
            before = String(base[..<index]) + format(last.pieces, base[..<index], base[index...])
            after = String(base[index...])
        } else {
            before = note.text
            after = ""
        }
        let tail = provisional.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else {
            self.provisional = ""
            return
        }
        var spaced = tail
        if let previous = before.last, !previous.isWhitespace { spaced = " " + spaced }
        if let next = after.first, !next.isWhitespace { spaced += " " }
        self.provisional = spaced
    }
}

/// A row of the notes list: the start of the note, and how its date shows.
enum NoteRowText {
    /// How much of a note's start a row holds; the row shows two lines of it.
    static let previewLength = 160

    /// The note's start on one line, nil for a note with no words yet.
    static func preview(_ text: String) -> String? {
        var line = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !line.isEmpty
                continue
            }
            if line.count + (pendingSpace ? 1 : 0) >= previewLength { break }
            if pendingSpace { line.append(" ") }
            pendingSpace = false
            line.append(character)
        }
        return line.isEmpty ? nil : line
    }

    /// The row's sentence for a note with no words yet.
    static let empty = "No words yet"

    enum DateStyle: Equatable, Sendable {
        /// Today: the time.
        case time
        /// This year: day and month.
        case dayAndMonth
        /// Earlier: day, month and year.
        case fullDate
    }

    static func dateStyle(_ date: Date, now: Date, calendar: Calendar) -> DateStyle {
        if calendar.isDate(date, inSameDayAs: now) { return .time }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return .dayAndMonth }
        return .fullDate
    }

    /// Said under the list when some notes did not open; nil when all did.
    static func unreadable(_ count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1: return "1 note couldn’t be opened."
        default: return "\(count) notes couldn’t be opened."
        }
    }
}

/// What swiping a row of the notes list offers: Pin or Unpin on the leading edge, Delete on the trailing edge. A note
/// that records, or is the core's note, offers neither; one with a run not yet merged offers Delete only, as its pin
/// waits for the merge.
struct NoteRowActions: Equatable, Sendable {
    enum Pin: Equatable, Sendable {
        case pin, unpin

        var title: String { self == .pin ? "Pin" : "Unpin" }
        var symbol: String { self == .pin ? "pin" : "pin.slash" }
        /// Whether the note is pinned once the action is taken.
        var pins: Bool { self == .pin }
    }

    /// Nil when the row offers no pin.
    var pin: Pin?
    var offersDelete: Bool
}

extension NoteRowActions {
    /// `recordingNoteID` is the session core's note; nil when none.
    init(note: Note, recordingNoteID: UUID?) {
        guard !note.isRecording, note.id != recordingNoteID else {
            self.init(pin: nil, offersDelete: false)
            return
        }
        self.init(pin: note.pendingRuns.isEmpty ? (note.isPinned ? .unpin : .pin) : nil, offersDelete: true)
    }
}

/// A search result's row: the text around the first match, on one line, with the matches inside it.
struct NoteSnippet: Equatable, Sendable {
    var text: String
    /// Character offsets into `text`.
    var highlights: [Range<Int>]

    /// Characters shown before the first match.
    static let lead = 32
    static let length = 140

    /// `matches` are character offsets into `text`, sorted (`NoteSearchHit.matchedCharacters`). Starts at a word, an
    /// ellipsis marks a cut, and line breaks show as spaces.
    init(text source: String, matches: [Range<Int>]) {
        let characters = Array(source)
        guard let first = matches.first, first.lowerBound < characters.count else {
            self.text = NoteRowText.preview(source) ?? ""
            highlights = []
            return
        }
        var start = max(0, first.lowerBound - Self.lead)
        if start > 0 {
            // From the first word that starts in the lead, so no word is cut at the front.
            var index = start
            while index < first.lowerBound, !characters[index - 1].isWhitespace { index += 1 }
            start = index
            while start < first.lowerBound, characters[start].isWhitespace { start += 1 }
        }
        var end = min(characters.count, start + Self.length)
        if end < characters.count {
            var index = end
            while index > first.upperBound, !characters[index].isWhitespace { index -= 1 }
            end = max(index, min(first.upperBound, characters.count))
        }
        let cutFront = start > 0, cutBack = end < characters.count
        var shown = String(characters[start ..< end].map { $0.isNewline ? " " : $0 })
        if cutBack { shown = shown.trimmingTrailingWhitespace() + "…" }
        let shift = cutFront ? 1 : 0
        text = (cutFront ? "…" : "") + shown
        let limit = text.count - (cutBack ? 1 : 0)
        highlights = matches.compactMap { match in
            let lower = max(match.lowerBound, start) - start + shift
            let upper = min(match.upperBound, end) - start + shift
            let clamped = min(upper, limit)
            return lower < clamped ? lower ..< clamped : nil
        }
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var text = self
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }
}

/// Where Resume puts the new speech: at the cursor, the end of a selection, or the note's end with no cursor.
enum NoteCursor {
    static func place(selection: Range<String.Index>?, in text: String) -> NoteRunPlace {
        guard let selection, selection.upperBound < text.endIndex else { return .end }
        return .offset(text.utf16.distance(from: text.utf16.startIndex, to: selection.upperBound))
    }
}

extension NoteError {
    /// A short, content-free sentence for the screens.
    var message: String {
        switch self {
        case .noPasscode: return NotesWords.passcodeNeeded
        case .vaultExists: return "Notes are already set up."
        case .noVault: return "Notes aren’t set up yet."
        case .secretMissing: return "This iPhone doesn’t have the key to your notes. Enter your recovery code."
        case .locked: return "Notes are locked."
        case .authenticationCancelled: return "Notes stayed locked."
        case .keyStoreFailed: return "The key to your notes couldn’t be reached."
        case .unavailable: return "Your notes couldn’t be read just now. Try again in a moment."
        case .storageFailed: return "Your notes couldn’t be saved."
        case .noRecoveryCode: return "No recovery code was made for these notes."
        case .malformedRecoveryCode: return "That isn’t a recovery code. It has 32 letters and digits."
        case .wrongRecoveryCode: return "That recovery code doesn’t open these notes."
        case .noSuchNote: return "This note no longer exists."
        case .noteIsRecording: return "A note is recording. Stop it first."
        case .runEnded: return "That recording had already ended."
        }
    }
}

extension NoteStartOutcome {
    /// Why a start did not record, in a short content-free sentence; nil when it started or stopped.
    var message: String? {
        switch self {
        case .started, .startedInBackground, .stopped: return nil
        case .busy: return "A note is already recording."
        case .needsApp(.noVault): return "Set up Notes first."
        case .needsApp(.microphone): return NoteEndReason.microphonePermissionDenied.message
        case .needsApp(.locked): return "Unlock your iPhone to record."
        case .needsApp(.foreground): return "Open Sorello to record."
        case .needsApp(.liveActivity): return "Turn on Live Activities for Sorello to record from here."
        case .failed(let reason): return reason.message ?? "The note stopped."
        }
    }
}

extension NoteEndReason {
    /// How a note ended, in a short content-free sentence; nil for the user's own stop.
    var message: String? {
        switch self {
        case .stopped: return nil
        case .reachedLimit: return "The note reached its time limit."
        case .sessionEnded: return "The session ended, so the note stopped."
        case .interrupted: return "A call or another app took the microphone."
        case .captureFailed: return "The microphone stopped."
        case .microphonePermissionDenied: return "Microphone access is off. Turn it on in Settings."
        case .modelUnavailable: return "This build has no speech model."
        case .modelFailed: return "The speech model couldn’t be prepared."
        case .transcriptionFailed: return "Transcription failed. What was saved is kept."
        case .storageFailed: return "The note couldn’t be saved."
        case .backgroundTimeExpired: return "iOS stopped the note in the background. What was saved is kept."
        case .noteGone: return "This note no longer exists."
        }
    }
}
