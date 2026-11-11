import Testing
@testable import SorelloUI

/// ARCHITECTURE.md, section 8, "Windows", the menu: the rows the menu-bar item's menu shows, from the top, for each
/// state the app can be in. The system draws them; these are the values it is given.
@MainActor
struct StatusMenuRowsTests {
    static let toggle = KeyCombo(modifiers: [.control(.either), .option(.either)], key: KeyName(label: "Space"))
    static let shortcuts: [ShortcutKind: KeyCombo] = [.holdToTalk: .function, .tapToToggle: toggle]

    static func rows(_ status: AppStatus, shortcuts: [ShortcutKind: KeyCombo] = shortcuts,
                     hasLastDictation: Bool = true) -> [StatusMenuRow] {
        StatusMenuRow.rows(appName: "Sorello", status: status, shortcuts: shortcuts,
                           hasLastDictation: hasLastDictation)
    }

    static let statuses = [
        AppStatus.sampleReady,
        AppStatus(model: .preparing, microphone: .granted, accessibility: .granted),
        AppStatus(model: .ready, microphone: .granted, accessibility: .granted, shortcutsPaused: true),
        AppStatus(model: .failed(.couldNotLoad), microphone: .granted, accessibility: .granted),
        AppStatus(model: .ready, microphone: .denied, accessibility: .granted),
        AppStatus(model: .ready, microphone: .granted, accessibility: .missing),
    ]

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

    /// A model not on this Mac: the remedy opens the General screen, where it is downloaded. While it downloads
    /// the menu says so, and when there is no build for this Mac it offers nothing.
    @Test func aModelToDownloadIsOfferedThroughGeneral() {
        let size: Int64 = 138_084_519
        let absent = Self.rows(AppStatus(model: .notDownloaded(.notStarted(size: size)), microphone: .granted,
                                         accessibility: .granted))
        #expect(Self.summary(absent) == ["information | Speech model not downloaded", "command openGeneral | Download…",
                                         "separator"] + Self.shortcutsAndBelow)
        #expect(absent.first?.image == .indicator(.problem))
        let failed = Self.rows(AppStatus(model: .notDownloaded(.failed(.server, size: size)), microphone: .granted,
                                         accessibility: .granted))
        #expect(Self.summary(failed) == Self.summary(absent))
        let downloading = Self.rows(AppStatus(model: .notDownloaded(.downloading(received: 5, size: size)),
                                              microphone: .granted, accessibility: .granted))
        #expect(Self.summary(downloading) == ["information | Downloading speech model", "separator"]
            + Self.shortcutsAndBelow)
        #expect(downloading.first?.image == .indicator(.preparing))
        let none = Self.rows(AppStatus(model: .notDownloaded(.unavailable), microphone: .granted,
                                       accessibility: .granted))
        #expect(Self.summary(none) == ["information | No speech model for this Mac yet", "separator"]
            + Self.shortcutsAndBelow)
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
        // The command opens the General screen, and says so. Access itself is granted in System Settings, which
        // General leads to, so the words do not say it is given here.
        #expect(rows[1].help == "Opens the General screen to manage microphone access")
    }

    @Test func missingAccessibilityLeadsToGeneral() {
        let rows = Self.rows(AppStatus(model: .ready, microphone: .granted, accessibility: .missing))
        #expect(Self.summary(rows) == ["information | Accessibility access needed", "command openGeneral | Fix…",
                                       "separator"] + Self.shortcutsAndBelow)
        #expect(rows[1].help == "Opens the General screen to manage Accessibility access")
    }

    @Test func withoutADictationCopyIsUnavailable() {
        let rows = Self.rows(.sampleReady, hasLastDictation: false)
        let unavailable = Self.shortcutsAndBelow.map {
            $0 == "command copyLastDictation | Copy Last Dictation"
                ? "unavailable copyLastDictation | Copy Last Dictation" : $0
        }
        #expect(Self.summary(rows) == ["information | Ready", "separator"] + unavailable)
    }

    /// The menu never shows what was dictated: in every state, with a dictation or without, the only heading is
    /// Shortcuts and the only row that is not a command is the state line.
    @Test func theStateLineIsTheOnlyRowThatIsNotACommand() {
        for status in Self.statuses {
            for hasLastDictation in [true, false] {
                let rows = Self.rows(status, hasLastDictation: hasLastDictation)
                #expect(rows.filter { $0.kind == .information }.map(\.id) == [.state])
                #expect(rows.filter { $0.kind == .heading }.map(\.title) == ["Shortcuts"])
            }
        }
    }

    /// Copy Last Dictation is a group of its own, between the shortcuts and the ways into the app.
    @Test func copyIsAGroupOfItsOwn() throws {
        for status in Self.statuses {
            let rows = Self.rows(status)
            let copy = try #require(rows.firstIndex { $0.command == .copyLastDictation })
            #expect(rows[copy - 1].kind == .separator && rows[copy + 1].kind == .separator)
            #expect(rows[copy - 2].command == .openShortcuts && rows[copy + 2].command == .openDictionary)
        }
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
                       AppStatus(model: .failed(.couldNotLoad), microphone: .denied, accessibility: .missing),
                       AppStatus(model: .notDownloaded(.notStarted(size: 9)), microphone: .denied,
                                 accessibility: .missing)] {
            let ids = Self.rows(status).map(\.id)
            #expect(Set(ids).count == ids.count)
        }
    }

    @Test func theModelGivesTheRowsOfItsValues() {
        let model = StatusMenuModel.sample(hasLastDictation: false)
        #expect(model.rows == StatusMenuRow.rows(appName: model.appName, status: model.status,
                                                 shortcuts: model.shortcuts, hasLastDictation: false))
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
