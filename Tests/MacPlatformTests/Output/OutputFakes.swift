import DictationCore
import DictionaryKit
import Foundation
import MacPlatform
import Synchronization

// Fakes for the output side of MacPlatform. None of them touches the system: no key is posted and no real pasteboard
// is read or written. All text is invented.

/// Everything the fakes saw, in order, so a test can assert the sequence and timing of a transaction.
enum OutputEvent: Equatable, Sendable {
    case compose(SeenDestination)
    case snapshotRead
    case clear
    case write([PasteboardItemData])
    case userCopy
    case post(key: UInt16, modifiers: ModifierFlags, at: TimeInterval)
}

/// An `InsertionDestination` reduced to what a test can compare.
enum SeenDestination: Equatable, Sendable {
    case cursor(InsertionContext?, SeenField?)
    case clipboard(ClipboardReason)

    init(_ destination: InsertionDestination) {
        switch destination {
        case .clipboard(let reason):
            self = .clipboard(reason)
        case .cursor(let context, let token):
            self = .cursor(context, token.map { token in
                guard let field = PreparedField.from(token) else { return SeenField(pid: -1, element: -1, selection: nil) }
                return SeenField(pid: field.target.pid, element: (field.target.element as? FakeElement)?.id ?? -1,
                                 selection: field.selection)
            })
        }
    }
}

struct SeenField: Equatable, Sendable {
    var pid: Int32
    var element: Int
    var selection: TextFieldRange?
}

final class EventLog: Sendable {
    private let events = Mutex<[OutputEvent]>([])

    func append(_ event: OutputEvent) { events.withLock { $0.append(event) } }

    var all: [OutputEvent] { events.withLock { $0 } }

    var posts: [OutputEvent] { all.filter { if case .post = $0 { true } else { false } } }

    var pasteboardEvents: [OutputEvent] {
        all.filter {
            switch $0 {
            case .snapshotRead, .clear, .write: true
            default: false
            }
        }
    }

    var composeCount: Int { all.filter { if case .compose = $0 { true } else { false } }.count }

    func clear() { events.withLock { $0 = [] } }
}

final class FakePasteboard: PasteboardAccess {
    struct State {
        var changeCount = 0
        var items: [PasteboardItemData] = []
        var unreadable = false
        var refuseWrites = false
        /// Runs during the snapshot read, as if another app wrote meanwhile.
        var onRead: (@Sendable () -> Void)?
        /// Runs after each successful write, once the items are on the pasteboard.
        var onWrite: (@Sendable () -> Void)?
    }

    let state = Mutex(State())
    private let log: EventLog

    init(log: EventLog) { self.log = log }

    func update(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }

    var items: [PasteboardItemData] { state.withLock { $0.items } }

    /// The user copies something in another app.
    func userCopies(_ items: [PasteboardItemData]) {
        state.withLock { state in
            state.changeCount += 1
            state.items = items
        }
        log.append(.userCopy)
    }

    var changeCount: Int { state.withLock { $0.changeCount } }

    func readItems(byteLimit: Int) -> PasteboardRead {
        log.append(.snapshotRead)
        let hook = state.withLock { $0.onRead }
        hook?()
        // The fake ignores the limit, so the transaction's own check is what a test sees.
        return state.withLock { $0.unreadable ? .unreadable : .items($0.items) }
    }

    func clear() -> Int {
        log.append(.clear)
        return state.withLock { state in
            state.changeCount += 1
            state.items = []
            return state.changeCount
        }
    }

    func write(_ items: [PasteboardItemData]) -> Bool {
        log.append(.write(items))
        let hook = state.withLock { state -> (@Sendable () -> Void)?? in
            guard !state.refuseWrites else { return nil }
            state.items += items
            return .some(state.onWrite)
        }
        guard let hook else { return false }
        hook?()
        return true
    }
}

final class FakeKeys: KeyPoster {
    struct State {
        var mayPost = true
        var modifiers: ModifierFlags = []
        var refusePosting = false
        /// Runs after a key is posted, with its code.
        var onPost: (@Sendable (UInt16) -> Void)?
    }

    let state = Mutex(State())
    private let log: EventLog
    private let clock: any SessionClock

    init(log: EventLog, clock: any SessionClock) {
        self.log = log
        self.clock = clock
    }

    func update(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }

    func mayPost() -> Bool { state.withLock { $0.mayPost } }

    func modifiersDown() -> ModifierFlags { state.withLock { $0.modifiers } }

    func post(key: UInt16, modifiers: ModifierFlags) -> Bool {
        guard let hook = state.withLock({ state -> (@Sendable (UInt16) -> Void)?? in
            state.refusePosting ? nil : .some(state.onPost)
        }) else { return false }
        log.append(.post(key: key, modifiers: modifiers, at: clock.now))
        hook?(key)
        return true
    }
}

final class FakeSession: UserSessionReading {
    let available = Mutex(true)

    func isAvailable() -> Bool { available.withLock { $0 } }
}

final class FakeFrontmost: FrontmostProcessReading {
    let pid = Mutex<Int32?>(FakeTextField.pid)

    @MainActor func frontmostProcessID() -> Int32? { pid.withLock { $0 } }
}
