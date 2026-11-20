import DictationCore
import DictionaryKit
import Foundation

/// One piece of a pasted sequence (ARCHITECTURE.md, section 14, "Pasting a note").
public enum PastePiece: Sendable, Equatable {
    case text(String)
    /// An image, as PNG data.
    case png(Data)
}

/// How a pasted sequence ended.
public enum PasteSequenceOutcome: Sendable, Equatable {
    /// Every piece was pasted.
    case pasted
    /// It stopped after `pasted` pieces; those stay where they were pasted.
    case stopped(pasted: Int, why: PasteSequenceStop)
}

public enum PasteSequenceStop: Sendable, Equatable {
    /// Nothing more could be posted: the session, Accessibility, a modifier held, or the app in front changed.
    case blocked(ClipboardReason)
    /// Someone else wrote to the clipboard while the sequence held it.
    case clipboardChanged
    case cancelled
    /// The pasteboard refused a piece, or a key could not be posted.
    case failed
}

/// Inserts a dictation by pasting it at the cursor of the app in front (ARCHITECTURE.md, section 6, "Text
/// insertion"). One insertion is one transaction, and transactions run one at a time in the order asked: the next
/// starts only after the previous one's Return and clipboard restore.
///
/// Everything the transaction touches is behind a seam (the pasteboard, key posting, the focused field, the
/// session, the app in front, the paste key and the clock), so its order, timing and every refusal can be tested
/// without posting a real key or touching the user's clipboard.
public final class PasteboardInserter: TextInserting {
    /// Step 1: how long to wait for Command, Option, Control and Shift to come up before giving up on posting.
    public static let modifierWaitLimit: TimeInterval = 1
    /// Step 1: how often the modifiers are looked at while waiting.
    public static let modifierPollInterval: TimeInterval = 0.01
    /// Step 6: how long after the paste Return is posted, so the app has taken the paste first.
    public static let returnDelay: TimeInterval = 0.08
    /// Step 7: how long after the paste the previous clipboard is put back, so the app has read the paste first.
    public static let restoreDelay: TimeInterval = 1
    /// In a sequence, how long after a text's paste, and after an image's, the next piece is written, so the app has
    /// taken each piece, in order, before the next (ARCHITECTURE.md, section 14, "Pasting a note").
    public static let textPieceDelay: TimeInterval = 0.3
    public static let imagePieceDelay: TimeInterval = 0.8

    private static let guardedModifiers: ModifierFlags = [.command, .option, .control, .shift]

    private let pasteboard: any PasteboardAccess
    private let keys: any KeyPoster
    private let probe: InsertionContextProbe
    private let session: any UserSessionReading
    private let frontmost: any FrontmostProcessReading
    private let pasteKey: @MainActor @Sendable () -> UInt16
    private let clock: any SessionClock
    private let line = TransactionLine()

    /// - Parameters:
    ///   - probe: reads the context around the cursor and checks the field again before keys are posted.
    ///   - pasteKey: the virtual key that pastes in the current layout; asked on the main thread just before the
    ///     paste is posted.
    ///   - clock: every wait in a transaction sleeps on it.
    public init(pasteboard: any PasteboardAccess, keys: any KeyPoster, probe: InsertionContextProbe,
                session: any UserSessionReading, frontmost: any FrontmostProcessReading,
                pasteKey: @escaping @MainActor @Sendable () -> UInt16 = { PasteKey.current() },
                clock: any SessionClock = SystemSessionClock()) {
        self.pasteboard = pasteboard
        self.keys = keys
        self.probe = probe
        self.session = session
        self.frontmost = frontmost
        self.pasteKey = pasteKey
        self.clock = clock
    }

    /// The inserter the app uses: the general pasteboard, real key events, and `reader` for the focused field.
    @MainActor
    public static func system(reader: any TextFieldReading) -> PasteboardInserter {
        PasteboardInserter(pasteboard: SystemPasteboard.general(), keys: SystemKeyPoster(),
                           probe: InsertionContextProbe(reader: reader), session: SystemUserSession(),
                           frontmost: SystemFrontmostProcess())
    }

    public func insert(restoreClipboard: Bool,
                       compose: @escaping @Sendable (InsertionDestination) async -> ComposedInsertion)
    async -> InsertionOutcome {
        guard await line.enter() else { return .failed(.cancelled) }
        let (outcome, afterPaste) = await transaction(restoreClipboard: restoreClipboard, compose: compose)
        if let afterPaste {
            // Return and the restore are the adapter's own work: a task the caller cannot cancel.
            let line = line
            Task {
                await afterPaste()
                await line.leave()
            }
        } else {
            await line.leave()
        }
        return outcome
    }

    /// Returns once every transaction asked for so far has finished, including its Return and its restore. The app
    /// awaits this before it quits, so a clipboard waiting to be put back is not lost.
    /// Takes a turn on the clipboard between insertions, for a write of the caller's own (a screen note's copy), so
    /// it never lands between an insertion's write and its paste or its restore. Returns false, without a turn, if the
    /// calling task is cancelled while it waits. Every turn taken is given back with `endClipboardWrite`.
    public func beginClipboardWrite() async -> Bool {
        await line.enter()
    }

    /// Gives back the turn `beginClipboardWrite` took.
    public func endClipboardWrite() async {
        await line.leave()
    }

    public func waitUntilIdle() async {
        await line.waitUntilIdle()
    }

    /// Pastes `pieces` one after another at the cursor of the app in front, in one turn on the line (ARCHITECTURE.md,
    /// section 14, "Pasting a note"). With `restoring`, the clipboard is put back 1 s after the last paste, under the
    /// same guards as an insertion's. Cancelling the calling task stops it before the next piece.
    public func pasteSequence(_ pieces: [PastePiece], restoring: Bool) async -> PasteSequenceOutcome {
        guard await line.enter() else { return .stopped(pasted: 0, why: .cancelled) }
        let (outcome, afterPaste) = await sequence(pieces, restoring: restoring)
        if let afterPaste {
            let line = line
            Task {
                await afterPaste()
                await line.leave()
            }
        } else {
            await line.leave()
        }
        return outcome
    }

    // MARK: - The transaction

    private typealias AfterPaste = @Sendable () async -> Void

    /// Where step 2 decided the text can go.
    private enum Route {
        /// To the cursor of `app`, with the field and context when they could be read.
        case cursor(app: Int32?, probed: ProbedField?)
        case clipboard(ClipboardReason)
    }

    private enum Key {
        case paste, returnKey
    }

    /// What happened at the moment a key was to be posted.
    private enum Posting {
        case posted(at: TimeInterval)
        case blocked(ClipboardReason)
        case cancelled
        case eventsUnavailable
    }

    private func transaction(restoreClipboard: Bool,
                             compose: @Sendable (InsertionDestination) async -> ComposedInsertion)
    async -> (InsertionOutcome, AfterPaste?) {
        // 1. Wait for the shortcut's modifiers to come up.
        do { try await waitForModifiers() } catch { return (.failed(.cancelled), nil) }

        // 2. Decide where the text can go. A clipboard-only destination reads no field.
        let route: Route
        if let reason = blockingReason() {
            route = .clipboard(reason)
        } else {
            let app = await frontmost.frontmostProcessID()
            route = .cursor(app: app, probed: await probe.read())
        }
        guard !Task.isCancelled else { return (.failed(.cancelled), nil) }

        // 3. Compose once, then classify before the clipboard is touched.
        let destination: InsertionDestination = switch route {
        case .clipboard(let reason): .clipboard(reason)
        case .cursor(_, let probed): .cursor(context: probed?.context, field: probed.map { DestinationField($0.field) })
        }
        let composed = await compose(destination)
        guard !Task.isCancelled else { return (.failed(.cancelled), nil) }
        if composed.text.isEmpty, !composed.pressEnter { return (.nothingToInsert, nil) }

        switch route {
        case .clipboard(let reason):
            guard !composed.text.isEmpty else { return (.failed(.commandNotPosted), nil) }
            guard ClipboardTransaction.write(composed.text, to: pasteboard, restoring: false) != nil else {
                return (.failed(.pasteboardUnavailable), nil)
            }
            // No key is ever posted on this path, so a cancellation that arrived during the write still wins. The
            // plain text has no copy to put back and stays.
            guard !Task.isCancelled else { return (.failed(.cancelled), nil) }
            return (.leftOnClipboard(reason), nil)
        case .cursor(let app, let probed):
            if composed.text.isEmpty {
                return (await postReturnAlone(app: app, field: probed?.field), nil)
            }
            return await paste(composed, app: app, field: probed?.field, restoring: restoreClipboard)
        }
    }

    private func sequence(_ pieces: [PastePiece], restoring: Bool) async -> (PasteSequenceOutcome, AfterPaste?) {
        do { try await waitForModifiers() } catch { return (.stopped(pasted: 0, why: .cancelled), nil) }
        if let reason = blockingReason() { return (.stopped(pasted: 0, why: .blocked(reason)), nil) }
        let app = await frontmost.frontmostProcessID()
        var clipboard: ClipboardTransaction?
        var pasted = 0
        var lastPaste: TimeInterval?

        /// Puts the clipboard back once the last piece pasted has had time to be read, if it is still the sequence's.
        func ending(_ outcome: PasteSequenceOutcome) -> (PasteSequenceOutcome, AfterPaste?) {
            guard let clipboard else { return (outcome, nil) }
            guard let lastPaste else {
                clipboard.restore()
                return (outcome, nil)
            }
            guard clipboard.willRestore else { return (outcome, nil) }
            return (outcome, { [self] in
                await sleep(until: lastPaste + Self.restoreDelay)
                if clipboard.restore() {
                    Diagnostics.record("insertion.clipboard.restored")
                } else {
                    Diagnostics.record("insertion.clipboard.left")
                }
            })
        }

        for piece in pieces {
            if Task.isCancelled { return ending(.stopped(pasted: pasted, why: .cancelled)) }
            let content = switch piece {
            case .text(let text): [PasteboardRepresentation(type: ClipboardTransaction.textType, data: Data(text.utf8))]
            case .png(let data): [PasteboardRepresentation(type: ClipboardTransaction.pngType, data: data)]
            }
            if let current = clipboard {
                guard current.isCurrent else {
                    // Someone else's copy is on the clipboard now: it is theirs, and nothing is put back over it.
                    return (.stopped(pasted: pasted, why: .clipboardChanged), nil)
                }
                guard let next = current.replacing(with: content) else {
                    return (.stopped(pasted: pasted, why: .failed), nil)
                }
                clipboard = next
            } else {
                guard let first = ClipboardTransaction.write(content, to: pasteboard, restoring: restoring) else {
                    return (.stopped(pasted: pasted, why: .failed), nil)
                }
                clipboard = first
            }
            switch await post(.paste, app: app, fieldConfirmed: true) {
            case .cancelled: return ending(.stopped(pasted: pasted, why: .cancelled))
            case .blocked(let reason): return ending(.stopped(pasted: pasted, why: .blocked(reason)))
            case .eventsUnavailable: return ending(.stopped(pasted: pasted, why: .failed))
            case .posted(let at):
                pasted += 1
                lastPaste = at
            }
            guard pasted < pieces.count else { break }
            if case .png = piece {
                await sleep(until: at(lastPaste) + Self.imagePieceDelay)
            } else {
                await sleep(until: at(lastPaste) + Self.textPieceDelay)
            }
        }
        return ending(.pasted)
    }

    private func at(_ time: TimeInterval?) -> TimeInterval { time ?? clock.now }

    /// Steps 4 to 7 for text: write it, check again, post Command-V, then hand back the guarded Return and restore.
    private func paste(_ composed: ComposedInsertion, app: Int32?, field: PreparedField?, restoring: Bool)
    async -> (InsertionOutcome, AfterPaste?) {
        guard let clipboard = ClipboardTransaction.write(composed.text, to: pasteboard, restoring: restoring) else {
            return (.failed(.pasteboardUnavailable), nil)
        }
        let fieldUnchanged = await confirm(field, sameSelection: true)
        switch await post(.paste, app: app, fieldConfirmed: fieldUnchanged) {
        case .cancelled:
            clipboard.restore()
            return (.failed(.cancelled), nil)
        case .blocked(let reason):
            // Left on the clipboard only if it really is there for the user to paste.
            guard clipboard.keepForUser() else { return (.failed(.pasteboardUnavailable), nil) }
            return (.leftOnClipboard(reason), nil)
        case .eventsUnavailable:
            clipboard.restore()
            return (.failed(.eventPostFailed), nil)
        case .posted(let pastedAt):
            let pressEnter = composed.pressEnter
            return (.inserted, { [self] in
                await finish(pastedAt: pastedAt, app: app, field: field, pressEnter: pressEnter, clipboard: clipboard)
            })
        }
    }

    /// Steps 6 and 7 after a posted paste. Nothing here posts the paste again, and nothing is retried.
    private func finish(pastedAt: TimeInterval, app: Int32?, field: PreparedField?, pressEnter: Bool,
                        clipboard: ClipboardTransaction) async {
        if pressEnter {
            await sleep(until: pastedAt + Self.returnDelay)
            // The paste moved the selection, so only the field's focus is checked.
            let fieldFocused = await confirm(field, sameSelection: false)
            if case .posted = await post(.returnKey, app: app, fieldConfirmed: fieldFocused) {
                Diagnostics.record("insertion.return.posted")
            } else {
                Diagnostics.record("insertion.return.skipped")
            }
        }
        if clipboard.willRestore {
            await sleep(until: pastedAt + Self.restoreDelay)
            if clipboard.restore() {
                Diagnostics.record("insertion.clipboard.restored")
            } else {
                Diagnostics.record("insertion.clipboard.left")
            }
        }
    }

    /// A dictation that is only "press enter": Return alone under step 4's checks, never touching the clipboard.
    private func postReturnAlone(app: Int32?, field: PreparedField?) async -> InsertionOutcome {
        let fieldUnchanged = await confirm(field, sameSelection: true)
        switch await post(.returnKey, app: app, fieldConfirmed: fieldUnchanged) {
        case .posted: return .inserted
        case .cancelled: return .failed(.cancelled)
        case .blocked, .eventsUnavailable: return .failed(.commandNotPosted)
        }
    }

    // MARK: - Checks

    private func waitForModifiers() async throws {
        try Task.checkCancellation()
        let deadline = clock.now + Self.modifierWaitLimit
        while modifiersAreDown(), clock.now < deadline {
            try await clock.sleep(for: min(Self.modifierPollInterval, deadline - clock.now))
        }
    }

    private func modifiersAreDown() -> Bool {
        !keys.modifiersDown().intersection(Self.guardedModifiers).isEmpty
    }

    /// Why nothing may be posted now, whatever the target: the session, Accessibility, or a held modifier.
    private func blockingReason() -> ClipboardReason? {
        if !session.isAvailable() { return .screenLocked }
        if !keys.mayPost() { return .accessibilityMissing }
        if modifiersAreDown() { return .modifiersStillDown }
        return nil
    }

    /// Whether the prepared field still has focus (and, with `sameSelection`, the same selection). With no prepared
    /// field there is nothing to check: the paste is a best effort into the same app.
    private func confirm(_ field: PreparedField?, sameSelection: Bool) async -> Bool {
        guard let field else { return true }
        return await probe.confirm(field, sameSelection: sameSelection)
    }

    /// Checks everything that can be checked synchronously and posts the key in the same main-actor turn, so nothing
    /// can change between the last check and the post. A cancelled caller posts nothing.
    private func post(_ key: Key, app: Int32?, fieldConfirmed: Bool) async -> Posting {
        await MainActor.run { [self] in
            if Task.isCancelled { return .cancelled }
            if let reason = blockingReason() { return .blocked(reason) }
            guard let app, frontmost.frontmostProcessID() == app, fieldConfirmed else { return .blocked(.targetChanged) }
            let posted = switch key {
            case .paste: keys.post(key: pasteKey(), modifiers: .command)
            case .returnKey: keys.post(key: KeyCode.returnKey, modifiers: [])
            }
            return posted ? .posted(at: clock.now) : .eventsUnavailable
        }
    }

    private func sleep(until time: TimeInterval) async {
        let remaining = time - clock.now
        guard remaining > 0 else { return }
        try? await clock.sleep(for: remaining)
    }
}
