import AppKit
import Synchronization

/// One type's data on a pasteboard item.
public struct PasteboardRepresentation: Sendable, Equatable {
    /// A uniform type identifier, such as `public.utf8-plain-text`.
    public var type: String
    /// The bytes offered for that type, exactly as the pasteboard holds them.
    public var data: Data

    /// One type and its data.
    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// One item on a pasteboard with every type it offers, in the order it offers them.
public struct PasteboardItemData: Sendable, Equatable {
    /// Every type the item offers, with its data.
    public var representations: [PasteboardRepresentation]

    /// An item offering `representations`, in that order.
    public init(_ representations: [PasteboardRepresentation]) {
        self.representations = representations
    }

    /// The number of bytes of data the item holds.
    public var byteCount: Int { representations.reduce(0) { $0 + $1.data.count } }
}

/// What reading every item on a pasteboard gave.
public enum PasteboardRead: Sendable, Equatable {
    /// Every item with every type's data.
    case items([PasteboardItemData])
    /// Some type's data could not be read, so a copy would be incomplete.
    case unreadable
    /// The data passed the byte limit; reading stopped there.
    case overLimit
}

/// The few pasteboard operations an insertion needs, so its logic can be tested against a fake and never touches
/// the user's clipboard in a test.
public protocol PasteboardAccess: Sendable {
    /// Grows whenever anyone changes the pasteboard's contents.
    var changeCount: Int { get }
    /// Every item with every type's data. Stops and reports `overLimit` as soon as the data passes `byteLimit`
    /// bytes, so an enormous clipboard is not copied into memory only to be thrown away.
    func readItems(byteLimit: Int) -> PasteboardRead
    /// Empties the pasteboard and takes ownership of it. Returns the change count this produced.
    func clear() -> Int
    /// Adds items to the pasteboard just cleared. Returns false when the system refused them.
    func write(_ items: [PasteboardItemData]) -> Bool
}

/// A `PasteboardAccess` over an `NSPasteboard`: the general pasteboard in the app, a uniquely named one in tests.
public final class SystemPasteboard: PasteboardAccess {
    private let pasteboard: Mutex<NSPasteboard>

    /// Wraps `pasteboard`. Every operation on it goes through this object's lock, one at a time.
    public init(_ pasteboard: sending NSPasteboard) {
        self.pasteboard = Mutex(pasteboard)
    }

    /// The general pasteboard, which is the user's clipboard.
    public static func general() -> SystemPasteboard { SystemPasteboard(NSPasteboard.general) }

    public var changeCount: Int { pasteboard.withLock { $0.changeCount } }

    public func readItems(byteLimit: Int) -> PasteboardRead {
        pasteboard.withLock { pasteboard in
            // Nil is a retrieval error, not an empty clipboard: a copy taken from it would be incomplete.
            guard let pasteboardItems = pasteboard.pasteboardItems else { return .unreadable }
            var items: [PasteboardItemData] = []
            var total = 0
            for item in pasteboardItems {
                var representations: [PasteboardRepresentation] = []
                for type in item.types {
                    guard let data = item.data(forType: type) else { return .unreadable }
                    total += data.count
                    guard total <= byteLimit else { return .overLimit }
                    representations.append(PasteboardRepresentation(type: type.rawValue, data: data))
                }
                items.append(PasteboardItemData(representations))
            }
            return .items(items)
        }
    }

    public func clear() -> Int {
        pasteboard.withLock { $0.clearContents() }
    }

    public func write(_ items: [PasteboardItemData]) -> Bool {
        // An item that offers no type cannot be written; there is nothing of it to put back.
        let writable = items.filter { !$0.representations.isEmpty }
        guard !writable.isEmpty else { return true }
        return pasteboard.withLock { pasteboard in
            let objects = writable.map { item in
                let object = NSPasteboardItem()
                for representation in item.representations {
                    object.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
                }
                return object
            }
            return pasteboard.writeObjects(objects)
        }
    }
}
