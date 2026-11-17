import Foundation

/// What the session's Live Activity shows (ARCHITECTURE.md, "Live Activity"): the dictation session's phase, the dates
/// its timers need and four flags, never any text or audio. It is the activity's content state, so it shows on the Lock
/// Screen and in the Dynamic Island. Compiled into the app, the activity extension and the host tests.
struct SessionActivityState: Codable, Hashable, Sendable {
    enum Phase: String, Codable, CaseIterable, Sendable {
        /// The session is listening for the keyboard; `endsAt` is its idle expiry.
        case ready
        /// A dictation is recording; `since` is when it was admitted.
        case recording
        /// The transcript is being made.
        case transcribing
        /// Stopped, and waiting for the model to finish preparing before transcribing.
        case preparing
        /// A voice note waits for the model; nothing is recorded yet.
        case notePreparing
        /// A voice note records; `since` is the note's start.
        case noteRecording
        /// A stopped voice note writes its last words.
        case noteSaving
        /// The short beat after a voice note was stopped, or ended at its cap.
        case noteSaved
    }

    var phase: Phase
    /// `ready`: when the session ends if nothing is dictated (the "ends in" countdown). A voice note preparing or
    /// recording on battery: when its cap stops it.
    var endsAt: Date?
    /// `recording`: when the recording started; `noteRecording`: when the note started (the live timer).
    var since: Date?
    /// A voice note: power is connected, so nothing counts down. Absent when false, as every flag.
    var onPower: Bool?
    /// A voice note on battery: its cap is `SessionActivityPolicy.noteWarning` away or less.
    var lastMinutes: Bool?
    /// `noteSaved`: the cap ended the note.
    var atLimit: Bool?
    /// `ready`: a vault exists, so the Live Activity offers to start a note.
    var offersNote: Bool?

    init(phase: Phase, endsAt: Date? = nil, since: Date? = nil, onPower: Bool = false, lastMinutes: Bool = false,
         atLimit: Bool = false, offersNote: Bool = false) {
        self.phase = phase
        self.endsAt = endsAt
        self.since = since
        self.onPower = onPower ? true : nil
        self.lastMinutes = lastMinutes ? true : nil
        self.atLimit = atLimit ? true : nil
        self.offersNote = offersNote ? true : nil
    }

    /// A voice note prepares or records: the Live Activity offers Stop.
    var isNoteInProgress: Bool { phase == .notePreparing || phase == .noteRecording }

    /// A voice note's phase, from its start to the beat after it.
    var isNote: Bool { isNoteInProgress || phase == .noteSaving || phase == .noteSaved }
}
