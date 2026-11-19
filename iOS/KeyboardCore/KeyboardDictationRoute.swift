#if SORELLO_KEYBOARD_DICTATION
import Foundation

/// Whether a mic tap dictates in the keyboard or goes to the host (ARCHITECTURE.md, "In-keyboard dictation
/// (experiment)", Host owns the microphone and Route). Pure: decided at the tap from the freshly read status and
/// intent, never from the mode on screen.
enum KeyboardDictationRoute {
    /// What the keyboard knows at a tap besides the shared files.
    struct Conditions: Equatable, Sendable {
        var hasFullAccess: Bool
        /// `keyboardDictationEnabled`.
        var enabled: Bool
        /// The app's microphone permission is granted (`AVAudioApplication.recordPermission`).
        var microphoneGranted: Bool
        /// The app's `Model/bundle.json` is readable from the keyboard.
        var modelCarried: Bool
        /// This instance's last in-keyboard dictation ended with `captureUnavailable`.
        var lastEndedCaptureUnavailable: Bool
        /// `keyboard-dictation.json` holds a record another keyboard process left unfinished, not yet handled by this
        /// process.
        var unfinishedRecordOfAnotherProcess: Bool
    }

    enum Decision: Equatable, Sendable {
        case keyboard
        case host
    }

    /// The host owns the microphone: a fresh, readable status of this schema showing a session active or starting, a
    /// voice note preparing or recording (a saving one holds none), or a dictation recording; or a `record` this instance
    /// wrote, still fresh within `pendingRecordTTL`, that the host has not answered (a bounce in flight). Used both to
    /// refuse a start and to revoke a dictation that runs.
    static func hostOwnsMicrophone(access: KeyboardAccess, status: StoreRead<HostStatus>, intent: StoreRead<KeyboardIntent>,
                                   instanceID: UUID, now: Date) -> Bool {
        guard access == .fullAccess else { return false }
        let status = status.value.flatMap { $0.schema == DictationProtocol.schema ? $0 : nil }
        if let status, DictationProtocol.isFresh(status.heartbeatAt, ttl: DictationProtocol.livenessTimeout, now: now) {
            if status.session == .active || status.session == .starting { return true }
            if let note = status.voiceNote, note.phase == .preparing || note.phase == .recording { return true }
            if status.dictation?.phase == .recording { return true }
        }
        guard let intent = intent.value, intent.schema == DictationProtocol.schema, intent.action == .record,
              intent.keyboardInstanceID == instanceID,
              DictationProtocol.isFresh(intent.issuedAt, ttl: DictationProtocol.pendingRecordTTL, now: now)
        else { return false }
        return status?.dictation?.requestID != intent.requestID
    }

    /// In the keyboard only when the host does not own the microphone, the presenter's mode for the same fresh state
    /// is `hostUnavailable`, and every condition holds.
    static func decide(access: KeyboardAccess, status: StoreRead<HostStatus>, intent: StoreRead<KeyboardIntent>,
                       instanceID: UUID, now: Date, conditions: Conditions) -> Decision {
        guard !hostOwnsMicrophone(access: access, status: status, intent: intent, instanceID: instanceID, now: now),
              KeyboardPresenter.mode(access: access, status: status, intent: intent, now: now) == .hostUnavailable,
              conditions.hasFullAccess, conditions.enabled, conditions.microphoneGranted, conditions.modelCarried,
              !conditions.lastEndedCaptureUnavailable, !conditions.unfinishedRecordOfAnotherProcess
        else { return .host }
        return .keyboard
    }
}
#endif
