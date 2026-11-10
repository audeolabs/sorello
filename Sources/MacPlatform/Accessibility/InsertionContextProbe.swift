import DictationCore
import DictionaryKit
import Dispatch
import Foundation
import Synchronization

/// What the probe read around the insertion point: the context for the text rules and the field it came from.
public struct ProbedField: Sendable {
    /// The text before and after the selection, for the text rules.
    public let context: InsertionContext
    /// The field and selection the context was read from.
    public let field: PreparedField

    /// Pairs a context with the field it was read from.
    public init(context: InsertionContext, field: PreparedField) {
        self.context = context
        self.field = field
    }
}

/// Reads a few characters on each side of the focused field's selection just before a paste, so the text rules can
/// fit the dictation to them, and checks the same field again before keys are posted. It reads another app's
/// text, so only the field's focus, role, secure state, character count, selection and at most `span` UTF-16 units
/// on each side are read, through a `TextFieldReading`. Nothing read is logged or kept after the insertion.
///
/// The reads run on the probe's own serial queue and race a deadline on the injected clock. Work that misses the
/// deadline is abandoned: it issues no further reads, and its late result is dropped, so a slow app never holds an
/// insertion up for long.
public final class InsertionContextProbe: Sendable {
    /// The most UTF-16 units read on each side of the selection.
    public static let span = 16
    /// How long one probe may take, in seconds, before it gives up and reports nothing.
    public static let deadline: TimeInterval = 0.3

    private let reader: any TextFieldReading
    private let clock: any SessionClock
    private let queue = DispatchQueue(label: "sorello.accessibility-reads", qos: .userInitiated)

    /// Reads through `reader`; the deadline runs on `clock`.
    public init(reader: any TextFieldReading, clock: any SessionClock = SystemSessionClock()) {
        self.reader = reader
        self.clock = clock
    }

    /// The context of another app's focused, editable, non-secure text field and the field it came from, or nil
    /// when there is none, nothing could be read, or the deadline passed. For a selection, the text before its
    /// start and after its end is read; the selection itself is not.
    public func read() async -> ProbedField? {
        await bounded { [reader] budget in Self.read(using: reader, budget: budget) }
    }

    /// Whether `field` is still the focused element of the same process, still not secure, and, when
    /// `sameSelection` is true, still has the selection it had when it was read. False when that cannot be
    /// established before the deadline.
    public func confirm(_ field: PreparedField, sameSelection: Bool) async -> Bool {
        await bounded { [reader] budget -> Bool? in
            guard budget.isLive, reader.isTrusted(), reader.check(field.target) == .ok, budget.isLive else {
                return false
            }
            guard sameSelection else { return true }
            guard budget.isLive, reader.selectedRange(field.target) == field.selection else { return false }
            return budget.isLive && reader.isTrusted() && reader.check(field.target) == .ok
        } ?? false
    }

    /// The reads themselves. As in the correction watch, the field is checked before every read and after the last
    /// one: a field that loses focus or turns secure meanwhile yields nothing, and so does work past its deadline.
    /// The budget is looked at again after each check, because a check is itself a call that can block past the
    /// deadline, and a read must never follow it then.
    private static func read(using reader: any TextFieldReading, budget: ReadBudget) -> ProbedField? {
        guard budget.isLive, reader.isTrusted(), let target = reader.captureFocusedTextField() else { return nil }
        func stillEligible() -> Bool {
            budget.isLive && reader.isTrusted() && reader.check(target) == .ok && budget.isLive
        }
        guard stillEligible(), let selection = reader.selectedRange(target),
              stillEligible(), let count = reader.characterCount(target),
              selection.location <= count - selection.length else { return nil }
        let start = max(0, selection.location - span)
        let end = selection.location + selection.length
        var before: String? = ""
        if selection.location > 0 {
            guard stillEligible() else { return nil }
            before = reader.string(target, range: TextFieldRange(location: start, length: selection.location - start))
        }
        var after: String? = ""
        if end < count {
            guard stillEligible() else { return nil }
            after = reader.string(target, range: TextFieldRange(location: end, length: min(span, count - end)))
        }
        guard stillEligible(), before != nil || after != nil else { return nil }
        return ProbedField(context: InsertionContext(before: before, after: after),
                           field: PreparedField(target: target, selection: selection))
    }

    /// Runs `work` on the probe's queue and returns its result, or nil if the deadline passes or the calling task
    /// is cancelled first. Either way the work's budget is spent, so it stops before its next read.
    private func bounded<Value: Sendable>(_ work: @escaping @Sendable (ReadBudget) -> Value?) async -> Value? {
        let race = DeadlineRace<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                race.begin(continuation)
                queue.async {
                    let value = race.budget.isLive ? work(race.budget) : nil
                    race.finish(value)
                }
                let clock = self.clock
                race.arm(Task {
                    do { try await clock.sleep(for: Self.deadline) } catch { return }
                    race.finish(nil)
                })
            }
        } onCancel: {
            race.finish(nil)
        }
    }
}

/// Whether a piece of Accessibility work may still issue reads. Spent once its deadline passes or its caller
/// gives up.
final class ReadBudget: Sendable {
    private let live = Mutex(true)

    var isLive: Bool { live.withLock { $0 } }

    func spend() { live.withLock { $0 = false } }
}

/// One read racing its deadline: whichever finishes first resumes the caller, exactly once.
private final class DeadlineRace<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value?, Never>?
        var timer: Task<Void, Never>?
        var result: Value??
    }

    let budget = ReadBudget()
    private let state = Mutex(State())

    func begin(_ continuation: CheckedContinuation<Value?, Never>) {
        let finished: Value?? = state.withLock { state in
            if state.result == nil { state.continuation = continuation }
            return state.result
        }
        if let finished { continuation.resume(returning: finished) }
    }

    func arm(_ timer: Task<Void, Never>) {
        let finished = state.withLock { state in
            if state.result == nil { state.timer = timer }
            return state.result != nil
        }
        if finished { timer.cancel() }
    }

    func finish(_ value: Value?) {
        let (continuation, timer) = state.withLock { state -> (CheckedContinuation<Value?, Never>?, Task<Void, Never>?) in
            guard state.result == nil else { return (nil, nil) }
            state.result = .some(value)
            defer { state.continuation = nil; state.timer = nil }
            return (state.continuation, state.timer)
        }
        budget.spend()
        timer?.cancel()
        continuation?.resume(returning: value)
    }
}
