import Testing
@testable import SorelloUI

/// ARCHITECTURE.md, section 8, "Windows", the menu: the rows the menu-bar item's menu shows, from the top, for each
/// state the app can be in. The system draws them; these are the values it is given.
@MainActor
struct StatusMenuRowsTests {
    static let toggle = KeyCombo(modifiers: [.control(.either), .option(.either)], key: KeyName(label: "Space"))
    static let shortcuts: [ShortcutKind: KeyCombo] = [.holdToTalk: .function, .tapToToggle: toggle]
    static let dictation = "Sphinx of black quartz, judge my vow. The five boxing wizards jump quickly."

    static func rows(_ status: AppStatus, shortcuts: [ShortcutKind: KeyCombo] = shortcuts,
                     lastDictation: String? = dictation) -> [StatusMenuRow] {
        StatusMenuRow.rows(appName: "Sorello", status: status, shortcuts: shortcuts, lastDictation: lastDictation)
    }

    /// One line per row, as a reader of the contract would list it.
    static func summary(_ rows: [StatusMenuRow]) -> [String] {
        rows.map { row in
            let kind = switch row.kind {
            case .heading: "heading"
            case .separator: "separator"
            case .information: "information"
            case .command(let command): row.isEnabled ? "command \(command)" : "unavailable \(command)"
            }
            return [kind, row.title, row.trailing ?? "", row.keyEquivalent.map { "⌘\($0)" } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " | ")
        }
    }

    /// Everything from the shortcuts' heading down, which no state changes.
    static let shortcutsAndBelow = [
        "heading | Shortcuts",
        "command openShortcuts | Hold to Talk | fn",
        "command openShortcuts | Tap to Toggle | ⌃⌥Space",
        "command openShortcuts | Paste Again | Not set",
        "separator",
        "heading | Last Dictation",
        "information | Sphinx of black quartz, judge my vow…",
        "command copyLastDictation | Copy Last Dictation",
        "separator",
        "command openDictionary | Dictionary",
        "command openRunLog | Run Log",
        "command openSettings | Settings… | ⌘,",
        "command quit | Quit Sorello | ⌘q",
    ]

    @Test func readyShowsTheStateWithoutARemedy() {
        let rows = Self.rows(.sampleReady)
        #expect(Self.summary(rows) == ["information | Ready", "separator"] + Self.shortcutsAndBelow)
        #expect(rows.first?.image == .indicator(.ready))
        #expect(rows.first?.isEnabled == false)
    }

    @Test func preparingShowsTheGlacierStateWithoutARemedy() {
        let rows = Self.rows(AppStatus(model: .preparing, microphone: .granted, accessibility: .granted))
        #expect(Self.summary(rows) == ["information | Preparing model", "separator"] + Self.shortcutsAndBelow)
        #expect(rows.first?.image == .indicator(.preparing))
    }

    @Test func pausedShortcutsShowTheGreyStateWithoutARemedy() {
        let rows = Self.rows(AppStatus(model: .ready, microphone: .granted, accessibility: .granted,
                                       shortcutsPaused: true))
        #expect(Self.summary(rows) == ["information | Shortcuts paused for a password field", "separator"]
            + Self.shortcutsAndBelow)
        #expect(rows.first?.image == .indicator(.neutral))
    }

    @Test func aFailedModelOffersRetry() {
        let rows = Self.rows(AppStatus(model: .failed(.couldNotLoad), microphone: .granted, accessibility: .granted))
        #expect(Self.summary(rows) == ["information | Speech model unavailable", "command retryModel | Retry",
                                       "separator"] + Self.shortcutsAndBelow)
        #expect(rows.first?.image == .indicator(.problem))
        #expect(rows[1].help == "Loads the speech model again")
    }

    @Test func aDeniedMicrophoneLeadsToGeneral() {
        let rows = Self.rows(AppStatus(model: .ready, microphone: .denied, accessibility: .granted))
        #expect(Self.summary(rows) == ["information | Microphone access needed", "command openGeneral | Fix…",
                                       "separator"] + Self.shortcutsAndBelow)
        #expect(rows.first?.image == .indicator(.problem))
        // The command opens Sorello's General screen, and says so: it does not open System Settings.
        #expect(rows[1].help == "Opens the General screen, where microphone access is given")
    }

    @Test func missingAccessibilityLeadsToGeneral() {
        let rows = Self.rows(AppStatus(model: .ready, microphone: .granted, accessibility: .missing))
        #expect(Self.summary(rows) == ["information | Accessibility access needed", "command openGeneral | Fix…",
                                       "separator"] + Self.shortcutsAndBelow)
        #expect(rows[1].help == "Opens the General screen, where Accessibility access is given")
    }

    @Test func withoutADictationTheLineSaysSoAndCopyIsUnavailable() {
        let rows = Self.rows(.sampleReady, lastDictation: nil)
        let section = Array(Self.summary(rows).drop { $0 != "heading | Last Dictation" }.prefix(3))
        #expect(section == ["heading | Last Dictation", "information | Nothing dictated yet.",
                            "unavailable copyLastDictation | Copy Last Dictation"])
    }

    @Test func everyShortcutCanBeUnset() {
        let rows = Self.rows(.sampleReady, shortcuts: [:])
        let section = Self.summary(rows).filter { $0.hasPrefix("command openShortcuts") }
        #expect(section == ["command openShortcuts | Hold to Talk | Not set",
                            "command openShortcuts | Tap to Toggle | Not set",
                            "command openShortcuts | Paste Again | Not set"])
    }

    /// A modifier alone, with its side, reads as the Shortcuts screen writes it inside a sentence; a key equivalent
    /// could not show it, and would fire the row when it was pressed.
    @Test func aModifierAloneIsShownAsTextNotAsAKeyEquivalent() throws {
        let rows = Self.rows(.sampleReady, shortcuts: [.holdToTalk: KeyCombo(modifiers: [.option(.right)]),
                                                       .pasteAgain: KeyCombo(modifiers: [.function, .shift(.either)],
                                                                             key: KeyName(label: "V"))])
        let shortcutRows = rows.filter { $0.command == .openShortcuts }
        #expect(shortcutRows.map(\.trailing) == ["Right ⌥", "Not set", "fn⇧V"])
        #expect(shortcutRows.allSatisfy { $0.keyEquivalent == nil && $0.isEnabled })
    }

    /// VoiceOver hears each shortcut's name and its keys in words, and an unset one as "Not set".
    @Test func voiceOverHearsEachShortcutInWords() {
        let rows = Self.rows(.sampleReady, shortcuts: [.holdToTalk: KeyCombo(modifiers: [.option(.right)]),
                                                       .tapToToggle: Self.toggle])
        #expect(rows.filter { $0.command == .openShortcuts }.map(\.accessibilityLabel) == [
            "Hold to Talk, Right Option", "Tap to Toggle, Control Option Space", "Paste Again, Not set",
        ])
        #expect(rows.first?.accessibilityLabel == "Ready")
    }

    @Test func theWaysIntoTheAppKeepTheirGlyphs() {
        let rows = Self.rows(.sampleReady)
        let images = rows.filter { $0.command != nil && $0.command != .openShortcuts }.map(\.image)
        #expect(images == [.symbol("doc.on.doc"), .symbol("character.book.closed"), .symbol("clock.arrow.circlepath"),
                           .symbol("gearshape"), .symbol("power")])
    }

    /// Each row keeps its identity whatever the state, so an open menu can change in place.
    @Test func rowsAreNamedUniquely() {
        for status in [AppStatus.sampleReady,
                       AppStatus(model: .failed(.missing), microphone: .denied, accessibility: .missing)] {
            let ids = Self.rows(status).map(\.id)
            #expect(Set(ids).count == ids.count)
        }
    }

    @Test func theModelGivesTheRowsOfItsValues() {
        let model = StatusMenuModel.sample(lastDictation: nil)
        #expect(model.rows == StatusMenuRow.rows(appName: model.appName, status: model.status,
                                                 shortcuts: model.shortcuts, lastDictation: nil))
    }

    @Test func eachCommandReachesItsAction() {
        var reported: [String] = []
        let actions = StatusMenuActions(
            copyLastDictation: { reported.append("copy") }, retryModel: { reported.append("retry") },
            openGeneral: { reported.append("general") }, openShortcuts: { reported.append("shortcuts") },
            openDictionary: { reported.append("dictionary") }, openRunLog: { reported.append("runlog") },
            openSettings: { reported.append("settings") }, quit: { reported.append("quit") })
        for command in [StatusMenuCommand.copyLastDictation, .retryModel, .openGeneral, .openShortcuts,
                        .openDictionary, .openRunLog, .openSettings, .quit] {
            actions.perform(command)
        }
        #expect(reported == ["copy", "retry", "general", "shortcuts", "dictionary", "runlog", "settings", "quit"])
    }
}

/// The last dictation in the menu: its start, on one line, short enough that the menu stays about as wide as an
/// ordinary menu.
@MainActor
struct LastDictationLineTests {
    static let limit = StatusMenuRow.lastDictationLimit

    @Test func theLimitKeepsTheMenuOrdinary() {
        #expect((30...48).contains(Self.limit))
    }

    @Test func shortTextIsShownWhole() {
        #expect(StatusMenuRow.lastDictationLine("Pack my box with five dozen liquor jugs.")
            == "Pack my box with five dozen liquor jugs.")
    }

    @Test func textOfExactlyTheLimitIsShownWhole() {
        let text = String(repeating: "abcd ", count: 20).prefix(Self.limit).description
        #expect(text.count == Self.limit)
        #expect(StatusMenuRow.lastDictationLine(text) == text.trimmingCharacters(in: .whitespaces))
    }

    @Test func longTextIsCutAtAWordAndEndsInAnEllipsis() {
        let line = StatusMenuRow.lastDictationLine(
            "Sphinx of black quartz, judge my vow. The five boxing wizards jump quickly over the lazy dog.")
        #expect(line == "Sphinx of black quartz, judge my vow…")
        #expect(line.count <= Self.limit)
    }

    @Test func lineBreaksAndRunsOfWhitespaceBecomeSingleSpaces() {
        #expect(StatusMenuRow.lastDictationLine("  Warm regards,\n\nAda\t \r\nNorthwind  ")
            == "Warm regards, Ada Northwind")
    }

    @Test func lineBreaksAreCollapsedBeforeTheTextIsCut() {
        let line = StatusMenuRow.lastDictationLine(
            "Dear Quillon Bay team,\n\nThe crates of pears arrive on Thursday morning at nine.")
        #expect(line == "Dear Quillon Bay team, The crates of…")
        #expect(!line.contains("\n"))
    }

    @Test func oneVeryLongWordIsCutWithinItself() {
        let word = String(repeating: "Vexlimer", count: 12)
        let line = StatusMenuRow.lastDictationLine(word)
        #expect(line.count == Self.limit)
        #expect(line.hasSuffix("…"))
        #expect(word.hasPrefix(line.dropLast()))
    }

    /// A word boundary near the start would leave the line nearly empty; the long word is cut instead.
    @Test func aBoundaryTooNearTheStartIsNotUsed() {
        let line = StatusMenuRow.lastDictationLine("Go " + String(repeating: "Okonkwo", count: 10))
        #expect(line.count == Self.limit)
        #expect(line.hasPrefix("Go Okonkwo"))
    }

    @Test func textOfOnlyWhitespaceSaysSo() {
        #expect(StatusMenuRow.lastDictationLine("\n\n") == "Spaces and line breaks only")
    }
}
