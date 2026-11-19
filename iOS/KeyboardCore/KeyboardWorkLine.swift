#if SORELLO_KEYBOARD_DICTATION
import Foundation

/// The in-keyboard engine's line of work (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Transcription): each
/// attempt's end and each release is queued behind what came before, and an attempt uses the engine only once all of
/// it has ended. A waiter whose own task is cancelled stops waiting at once and gets nothing, so work queued behind its
/// own end never waits on it.
@MainActor
final class KeyboardWorkLine {
    private var tail: Task<Void, Never>?

    /// Queues `work` behind everything queued so far.
    func then(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Waits until everything queued, including what is queued meanwhile, has ended. False, at once, when the calling
    /// task is cancelled before or during the wait.
    func waitUntilFree() async -> Bool {
        while true {
            guard !Task.isCancelled else { return false }
            let awaited = tail
            await awaited?.value
            guard !Task.isCancelled else { return false }
            if tail == awaited { return true }
        }
    }
}
#endif
