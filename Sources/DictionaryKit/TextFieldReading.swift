import Foundation

// Reading the text field in front (ARCHITECTURE.md, section 6, "Accessibility reads"). The correction watch here
// and the insertion adapter on macOS both read another app's text only through this protocol, so every such read
// is bounded and never touches a secure field. The macOS implementation is in MacPlatform; tests use a fake.

/// The process in front and its focused text element. Only the adapter that implements `TextFieldReading` makes
/// these and looks inside them.
public struct TextFieldTarget: Sendable {
    public let pid: Int32
    /// The adapter's own handle for the element. Its type is the adapter's business and must be `Sendable`: the
    /// macOS adapter wraps its Accessibility reference in a type of its own and answers for that type's thread
    /// safety there; a test's fake uses any small `Sendable` value.
    public let element: any Sendable

    public init(pid: Int32, element: any Sendable) {
        self.pid = pid
        self.element = element
    }
}

/// UTF-16 offsets, as Accessibility reports them.
public struct TextFieldRange: Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public enum TextFieldCheck: Equatable, Sendable {
    case ok, focusChanged, secure, failed
}

/// Bounded reads of one text field in another app. Implementations never read a whole value, and treat a field
/// that is secure, or whose security cannot be determined, as unreadable.
public protocol TextFieldReading: AnyObject, Sendable {
    func isTrusted() -> Bool
    /// The focused element of the app in front, if it is another app's editable text area, text field or combo box
    /// and not a secure field.
    func captureFocusedTextField() -> TextFieldTarget?
    /// Whether `target` is still the same process's focused element, and still not secure.
    func check(_ target: TextFieldTarget) -> TextFieldCheck
    func characterCount(_ target: TextFieldTarget) -> Int?
    func selectedRange(_ target: TextFieldTarget) -> TextFieldRange?
    /// The text in `range`, or nil when unsupported or on any error.
    func string(_ target: TextFieldTarget, range: TextFieldRange) -> String?
}
