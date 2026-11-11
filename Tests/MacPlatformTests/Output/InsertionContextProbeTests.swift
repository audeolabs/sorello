import DictationCore
import DictionaryKit
import Dispatch
import Foundation
import MacPlatform
import Testing

/// Reading the text around the insertion point of the focused field, ported from the reference probe's tests, plus
/// the deadline and the checks made again before keys are posted. A fake reader stands in for Accessibility; all
/// text is invented.
@Suite struct InsertionContextProbeTests {
    private func read(_ field: FakeTextField, clock: ManualClock = ManualClock()) async -> InsertionContext? {
        await InsertionContextProbe(reader: field, clock: clock).read()?.context
    }

    @Test func readsAroundTheCaret() async {
        let field = FakeTextField("Like this one. Next.")
        field.update { $0.caret = "Like this one".utf16.count }
        #expect(await read(field) == InsertionContext(before: "Like this one", after: ". Next."))
    }

    @Test func readsAroundASelection() async {
        let field = FakeTextField("Keep this, drop that, keep.")
        field.update {
            $0.caret = "Keep this, ".utf16.count
            $0.selectionLength = "drop that".utf16.count
        }
        #expect(await read(field) == InsertionContext(before: "Keep this, ", after: ", keep."))
    }

    @Test func caretAtEitherEnd() async {
        let field = FakeTextField("Some words")
        field.update { $0.caret = 0 }
        #expect(await read(field) == InsertionContext(before: "", after: "Some words"))
        field.update { $0.caret = $0.units.count }
        #expect(await read(field) == InsertionContext(before: "Some words", after: ""))
        let empty = FakeTextField("")
        #expect(await read(empty) == InsertionContext(before: "", after: ""))
        #expect(empty.state.withLock { $0.rangeReads }.isEmpty)
    }

    @Test func readsOnlyAFewCharacters() async {
        let filler = String(repeating: "synthetic filler ", count: 20)
        let field = FakeTextField(filler + "|" + filler)
        field.update { $0.caret = filler.utf16.count }
        let context = await read(field)
        #expect(context?.before?.utf16.count == InsertionContextProbe.span)
        #expect(context?.after?.utf16.count == InsertionContextProbe.span)
        #expect(field.state.withLock { $0.rangeReads }.allSatisfy { $0.length <= InsertionContextProbe.span })
    }

    @Test(arguments: ["untrusted", "unfocused", "secure"])
    func nothingWithoutAnEligibleField(_ condition: String) async {
        let field = FakeTextField("Private words")
        field.update { state in
            switch condition {
            case "untrusted": state.trusted = false
            case "unfocused": state.focused = false
            default: state.secure = true
            }
        }
        #expect(await InsertionContextProbe(reader: field, clock: ManualClock()).read() == nil)
        #expect(field.state.withLock { $0.rangeReads }.isEmpty)
    }

    @Test func failedReads() async {
        let failing = FakeTextField("Some words")
        failing.update { $0.failReads = true }
        #expect(await read(failing) == nil)

        // A field without range reads gives nothing; the whole value is never read instead.
        let unsupported = FakeTextField("Some words")
        unsupported.update {
            $0.caret = 4
            $0.supportsRangeReads = false
        }
        #expect(await read(unsupported) == nil)

        // A selection past the end is inconsistent: nothing is trusted.
        let inconsistent = FakeTextField("Some words")
        inconsistent.update { $0.selectionLength = 3 }
        #expect(await read(inconsistent) == nil)
    }

    /// As in the correction watch: a field that turns secure or loses focus during a read yields nothing more.
    @Test func checksTheFieldBeforeEveryRead() async {
        let field = FakeTextField("Some words")
        field.update { $0.caret = 4 }
        #expect(await read(field) != nil)
        #expect(field.state.withLock { $0.uncheckedReads } == 0)

        for change in ["secure", "unfocused", "untrusted"] {
            let changing = FakeTextField("Private words")
            changing.update { $0.caret = 7 }
            changing.update { state in
                state.onCharacterCount = { [changing] in
                    changing.update { state in
                        switch change {
                        case "secure": state.secure = true
                        case "unfocused": state.focused = false
                        default: state.trusted = false
                        }
                    }
                }
            }
            #expect(await read(changing) == nil, "No context once the field is \(change)")
            #expect(changing.state.withLock { $0.rangeReads }.isEmpty)
        }
    }

    @Test func namesTheFieldAndSelectionItRead() async {
        let field = FakeTextField("Keep this, drop that, keep.")
        field.update {
            $0.caret = 5
            $0.selectionLength = 4
        }
        let probed = await InsertionContextProbe(reader: field, clock: ManualClock()).read()
        #expect(probed?.field.target.pid == FakeTextField.pid)
        #expect(probed?.field.target.element as? FakeElement == FakeElement(id: 1))
        #expect(probed?.field.selection == TextFieldRange(location: 5, length: 4))
    }

    /// A slow app cannot hold an insertion up: after 0.3 s the probe reports nothing, and the abandoned work issues
    /// no further reads once the app finally answers.
    @Test func givesUpAtTheDeadlineAndAbandonsTheWork() async {
        let field = FakeTextField("Some invented words")
        field.update { $0.caret = 4 }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        field.update { state in
            state.onCharacterCount = {
                entered.signal()
                release.wait()
            }
        }
        let clock = ManualClock()
        let probe = InsertionContextProbe(reader: field, clock: clock)
        let reading = Task { await probe.read() }

        await waitForSignal(entered)
        #expect(await clock.nextDeadline() == InsertionContextProbe.deadline)
        clock.advance(to: InsertionContextProbe.deadline - 0.01)
        clock.advance(to: InsertionContextProbe.deadline)
        let result = await finished(reading)
        #expect(result != nil, "The read finished")
        #expect(result.flatMap { $0 } == nil, "and found nothing")

        let callsAtDeadline = field.state.withLock { $0.calls.count }
        field.update {
            $0.onCharacterCount = nil
            $0.trusted = false
        }
        release.signal()
        // The probe's queue is serial: this read runs after the abandoned one has finished.
        #expect(await probe.read() == nil)
        let later = field.state.withLock { Array($0.calls[callsAtDeadline...]) }
        #expect(later == ["isTrusted"], "The abandoned work read nothing after its deadline")
        #expect(field.state.withLock { $0.rangeReads }.isEmpty)
    }

    /// The check before a range read can itself block past the deadline; when it finally answers, the abandoned
    /// work must not go on to read the text.
    @Test func noReadFollowsACheckThatOutlivedTheDeadline() async {
        let field = FakeTextField("Some invented words")
        field.update { $0.caret = 4 }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        field.update { state in
            // The next check after the character count is the one before the first range read.
            state.onCharacterCount = { [field] in
                field.update { state in
                    state.onCharacterCount = nil
                    state.onCheck = { [field] in
                        field.update { $0.onCheck = nil }
                        entered.signal()
                        release.wait()
                    }
                }
            }
        }
        let clock = ManualClock()
        let probe = InsertionContextProbe(reader: field, clock: clock)
        let reading = Task { await probe.read() }

        await waitForSignal(entered)
        _ = await clock.nextDeadline()
        clock.advance(to: InsertionContextProbe.deadline)
        let result = await finished(reading)
        #expect(result != nil, "The read finished")
        #expect(result.flatMap { $0 } == nil, "and found nothing")

        let callsAtDeadline = field.state.withLock { $0.calls.count }
        field.update { $0.trusted = false }
        release.signal()
        #expect(await probe.read() == nil)
        let later = field.state.withLock { Array($0.calls[callsAtDeadline...]) }
        #expect(later == ["isTrusted"], "The abandoned work read nothing after its deadline")
        #expect(field.state.withLock { $0.rangeReads }.isEmpty)
    }

    @Test func confirmsTheSameFieldAndSelection() async {
        let field = FakeTextField("Some invented words")
        field.update { $0.caret = 4 }
        let probe = InsertionContextProbe(reader: field, clock: ManualClock())
        guard let prepared = await probe.read()?.field else {
            Issue.record("The field was not read")
            return
        }
        #expect(await probe.confirm(prepared, sameSelection: true))

        field.update { $0.caret = 6 }
        #expect(await probe.confirm(prepared, sameSelection: true) == false)
        #expect(await probe.confirm(prepared, sameSelection: false), "Only focus is checked without the selection")

        // Another field of the same app has focus; the prepared one keeps its selection.
        field.update {
            $0.caret = 4
            $0.focusedElement = 2
        }
        #expect(await probe.confirm(prepared, sameSelection: true) == false)
        #expect(await probe.confirm(prepared, sameSelection: false) == false)

        field.update {
            $0.focusedElement = 1
            $0.secure = true
        }
        #expect(await probe.confirm(prepared, sameSelection: false) == false)
    }
}

/// Waits for a semaphore without blocking the cooperative pool.
private func waitForSignal(_ semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            semaphore.wait()
            continuation.resume()
        }
    }
}

@Suite struct AccessibilityTextFieldReaderTests {
    /// A target made by anything other than this reader carries a payload it does not know; every read fails
    /// instead of crashing, and no Accessibility call is made with it.
    @Test func aTargetWithAnotherPayloadFails() {
        let reader = AccessibilityTextFieldReader()
        let target = TextFieldTarget(pid: 4242, element: FakeElement(id: 1))
        #expect(reader.check(target) == .failed)
        #expect(reader.characterCount(target) == nil)
        #expect(reader.selectedRange(target) == nil)
        #expect(reader.string(target, range: TextFieldRange(location: 0, length: 4)) == nil)
    }
}
