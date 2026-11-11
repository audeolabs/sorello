import DictationCore
import DictionaryKit

/// The field and selection an insertion read its context from. The inserter hands it to `compose` inside a
/// `DestinationField`, checks it again before posting, and the app layer unwraps it to anchor the correction watch,
/// so the watch and the paste can never disagree about which field the text went to.
public struct PreparedField: Sendable {
    /// The focused field of the app in front, as the reader captured it.
    public let target: TextFieldTarget
    /// Its selection when the context was read, in UTF-16 units. The paste replaces this range.
    public let selection: TextFieldRange

    /// Names a captured field and the selection read from it.
    public init(target: TextFieldTarget, selection: TextFieldRange) {
        self.target = target
        self.selection = selection
    }

    /// The prepared field inside a destination's token, or nil when the token holds something else or there is
    /// none. This is how the app layer opens what the session passes along unopened.
    public static func from(_ token: DestinationField?) -> PreparedField? {
        token?.value as? PreparedField
    }
}
