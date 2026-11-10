import DictationCore
import Foundation
import Testing

@Suite("What the pill shows")
struct PillContentTests {
    @Test func hiddenWhenNothingIsGoingOn() {
        #expect(PillContent(Machine().state) == .hidden)
    }

    @Test func listeningWhileStartingAndRecording() {
        var machine = Machine()
        machine.press(.toggle, at: 42)
        let listening = PillContent.listening(ListeningPill(id: id1, mode: .toggle, style: .plain, since: 42))
        #expect(PillContent(machine.state) == listening)
        machine.started(id1)
        #expect(PillContent(machine.state) == listening)
    }

    @Test func listeningOutranksAnErrorAndTheWait() {
        var machine = Machine()
        let older = machine.recordHold(at: 1)
        machine.press(.hold, at: 4)
        machine.started(id2)
        machine.send(.transcript(older, .failure(.failed)))
        #expect(machine.state.notice?.kind == .error)
        #expect(PillContent(machine.state) == .listening(ListeningPill(id: id2, mode: .hold, style: .plain, since: 4)))
    }

    @Test func anErrorOutranksTheWait() {
        var machine = Machine()
        machine.recordHold(at: 1)
        machine.press(.hold, at: 4)
        machine.fire(.captureStart(id2))
        let notice = machine.state.notice
        #expect(notice?.message == .microphoneUnavailable)
        #expect(PillContent(machine.state) == notice.map(PillContent.notice))
    }

    @Test func waitingWhileAnyDictationRemains() {
        var machine = Machine()
        let id = machine.recordHold(at: 1)
        #expect(PillContent(machine.state) == .waiting(preparingModel: false))
        machine.transcript(id, "Invented")
        #expect(PillContent(machine.state) == .waiting(preparingModel: false), "while it is inserted")
    }

    @Test func waitingExplainsAModelStillPreparing() {
        var machine = Machine(engine: .preparing)
        machine.recordHold(at: 1)
        #expect(PillContent(machine.state) == .waiting(preparingModel: true))
        machine.send(.engine(.ready))
        #expect(PillContent(machine.state) == .waiting(preparingModel: false))
    }

    @Test func theWaitOutranksInformation() {
        var machine = Machine()
        let quiet = machine.recordHold(at: 1)
        machine.recordHold(at: 4)
        machine.transcript(quiet, "")
        #expect(machine.state.notice?.kind == .information)
        #expect(PillContent(machine.state) == .waiting(preparingModel: false))
    }

    @Test func informationWhenNothingElseIsGoingOn() {
        var machine = Machine()
        let quiet = machine.recordHold(at: 1)
        machine.transcript(quiet, "")
        #expect(PillContent(machine.state) == machine.state.notice.map(PillContent.notice))
    }

    @Test func nothingWhileThePermissionPromptIsUp() {
        var machine = Machine(microphone: .unknown, engine: .ready)
        machine.press(.hold, at: 1)
        #expect(PillContent(machine.state) == .hidden)
    }

    @Test func promptStyleIsShown() {
        var machine = Machine(settings: SessionSettings(doubleTap: .prompt))
        machine.press(.hold, at: 1)
        machine.release(at: 1.1)
        machine.press(.hold, at: 1.2)
        #expect(PillContent(machine.state) == .listening(ListeningPill(id: id2, mode: .hold, style: .prompt,
                                                                       since: 1.2)))
    }

    @Test func aHandsFreeRecordingIsTheListeningPillInToggleMode() {
        var machine = Machine()
        machine.press(.hold, at: 1)
        machine.release(at: 1.1)
        machine.press(.hold, at: 1.3)
        let listening = PillContent.listening(ListeningPill(id: id2, mode: .toggle, style: .plain, since: 1.3))
        #expect(PillContent(machine.state) == listening)
        machine.started(id2)
        machine.release(at: 1.4)
        #expect(PillContent(machine.state) == listening, "after the second press comes up too")
    }

    @Test func everyNoticeHasText() {
        let messages: [NoticeMessage] = [
            .busy, .microphoneDenied, .engineFailed(.modelMissing), .engineFailed(.modelCorrupt),
            .engineFailed(.loadFailed), .microphoneUnavailable, .nothingHeard, .transcriptionFailed,
            .leftOnClipboard(.accessibilityMissing), .leftOnClipboard(.modifiersStillDown),
            .leftOnClipboard(.screenLocked), .leftOnClipboard(.targetChanged),
            .insertionFailed(.commandNotPosted), .insertionFailed(.eventPostFailed),
            .insertionFailed(.pasteboardUnavailable), .insertionFailed(.cancelled),
        ]
        for message in messages { #expect(!message.text.isEmpty) }
        #expect(messages.filter { $0.kind == .information } == [.nothingHeard])
    }
}
