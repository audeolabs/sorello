import Foundation

/// One row of the menu-bar item's menu, as plain values (ARCHITECTURE.md, section 8, "Windows"). The system draws
/// the menu in its own material and font; a row says only what AppKit gives a menu item: a title, a glyph, text at
/// the trailing edge, a key equivalent, whether it is a command and whether it can be used now.
nonisolated public struct StatusMenuRow: Equatable, Sendable {
    /// Which row this is. A row keeps its identity whatever the values, so an open menu can change in place.
    public enum ID: Hashable, Sendable {
        case state
        case remedy
        case shortcutsHeading
        case shortcut(ShortcutKind)
        case copyLastDictation
        case dictionary
        case runLog
        case settings
        case quit
        /// The separator after the given group: 1 after the state, 2 after the shortcuts, 3 after Copy Last Dictation.
        case separator(Int)
    }

    /// What a row is.
    public enum Kind: Equatable, Sendable {
        /// A section heading, drawn by the system as one.
        case heading
        /// A hairline between groups.
        case separator
        /// Words to read that are not a command: the state line.
        case information
        /// A row that does something when chosen.
        case command(StatusMenuCommand)
    }

    /// The glyph before a row's title.
    public enum Image: Equatable, Sendable {
        /// The state's mark, in the state's colour: a dot, or the ember warning symbol for a problem.
        case indicator(StatusLine.Indicator)
        /// An SF Symbol, drawn by the menu in its own text colour.
        case symbol(String)
    }

    public let id: ID
    public let kind: Kind
    /// The row's words. Empty for a separator.
    public let title: String
    /// Text at the row's trailing edge: a shortcut's keys, or "Not set".
    public let trailing: String?
    /// A key that chooses the row with ⌘ while the menu is open, written as AppKit takes it: "," or "q".
    public let keyEquivalent: String?
    public let image: Image?
    /// Whether choosing the row does something now. Never true for a row that is not a command.
    public let isEnabled: Bool
    /// What VoiceOver reads for the row, when its title alone would not say enough.
    public let accessibilityLabel: String?
    /// What a command does, for VoiceOver and as a tooltip.
    public let help: String?

    /// A row; anything not given is absent, and a row is enabled only if it is a command.
    public init(id: ID, kind: Kind, title: String = "", trailing: String? = nil, keyEquivalent: String? = nil,
                image: Image? = nil, isEnabled: Bool? = nil, accessibilityLabel: String? = nil, help: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.trailing = trailing
        self.keyEquivalent = keyEquivalent
        self.image = image
        if case .command = kind { self.isEnabled = isEnabled ?? true } else { self.isEnabled = false }
        self.accessibilityLabel = accessibilityLabel
        self.help = help
    }

    /// The command a row runs, if it is one.
    public var command: StatusMenuCommand? {
        if case .command(let command) = kind { command } else { nil }
    }

    /// The menu's rows from the top: the state and its remedy, the shortcuts, Copy Last Dictation, then the ways into
    /// the app and Quit, with separators between the four groups. No row carries a dictation's text; Copy can be used
    /// when `hasLastDictation` is true.
    public static func rows(appName: String, status: AppStatus, shortcuts: [ShortcutKind: KeyCombo],
                            hasLastDictation: Bool) -> [StatusMenuRow] {
        let line = status.line
        var rows = [StatusMenuRow(id: .state, kind: .information, title: line.text, image: .indicator(line.indicator),
                                  accessibilityLabel: line.text)]
        if let remedy = line.remedy {
            rows.append(StatusMenuRow(id: .remedy, kind: .command(remedy == .retryModel ? .retryModel : .openGeneral),
                                      title: remedy.title, help: remedy.hint))
        }

        rows.append(StatusMenuRow(id: .separator(1), kind: .separator))
        rows.append(StatusMenuRow(id: .shortcutsHeading, kind: .heading, title: String(localized: "Shortcuts")))
        let notSet = String(localized: "Not set")
        for kind in ShortcutKind.allCases {
            let keys = shortcuts[kind]
            let spoken = keys?.spokenLabel ?? notSet
            rows.append(StatusMenuRow(
                id: .shortcut(kind), kind: .command(.openShortcuts), title: kind.title,
                trailing: keys?.inlineLabel ?? notSet,
                accessibilityLabel: String(localized: "\(kind.title), \(spoken)",
                                           comment: "VoiceOver: a shortcut's action, then its keys in words")))
        }

        rows.append(StatusMenuRow(id: .separator(2), kind: .separator))
        rows.append(StatusMenuRow(id: .copyLastDictation, kind: .command(.copyLastDictation),
                                  title: String(localized: "Copy Last Dictation"), image: .symbol("doc.on.doc"),
                                  isEnabled: hasLastDictation))

        rows.append(StatusMenuRow(id: .separator(3), kind: .separator))
        rows.append(StatusMenuRow(id: .dictionary, kind: .command(.openDictionary),
                                  title: String(localized: "Dictionary"), image: .symbol("character.book.closed")))
        rows.append(StatusMenuRow(id: .runLog, kind: .command(.openRunLog), title: String(localized: "Run Log"),
                                  image: .symbol("clock.arrow.circlepath")))
        rows.append(StatusMenuRow(id: .settings, kind: .command(.openSettings), title: String(localized: "Settings…"),
                                  keyEquivalent: ",", image: .symbol("gearshape")))
        rows.append(StatusMenuRow(id: .quit, kind: .command(.quit), title: String(localized: "Quit \(appName)"),
                                  keyEquivalent: "q", image: .symbol("power")))
        return rows
    }
}
