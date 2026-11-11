import Testing
@testable import SorelloUI

/// ARCHITECTURE.md, sections 6 ("Updates") and 8 ("Windows"): a build that can update itself has one more row, just
/// above Quit: Check for Updates…, or Update Available… once a check made on its own has found a newer version. A
/// build with no update feed has no such row, and its menu is as it was.
@MainActor
struct StatusMenuUpdateRowTests {
    static func rows(_ updates: UpdateRowState?) -> [StatusMenuRow] {
        StatusMenuRow.rows(appName: "Sorello", status: .sampleReady, shortcuts: StatusMenuRowsTests.shortcuts,
                           hasLastDictation: true, updates: updates)
    }

    @Test func aBuildWithoutAFeedHasNoUpdateRow() {
        let rows = Self.rows(nil)
        #expect(StatusMenuRowsTests.summary(rows) == ["information | Ready", "separator"]
            + StatusMenuRowsTests.shortcutsAndBelow)
        #expect(!rows.contains { $0.id == .updates || $0.command == .checkForUpdates })
    }

    @Test func checkForUpdatesSitsAboveQuit() {
        let rows = Self.rows(.checkForUpdates(isEnabled: true))
        #expect(Array(StatusMenuRowsTests.summary(rows).suffix(3)) == [
            "command openSettings | Settings… | ⌘,",
            "command checkForUpdates | Check for Updates…",
            "command quit | Quit Sorello | ⌘q",
        ])
        let row = rows.first { $0.id == .updates }
        #expect(row?.image == .symbol("arrow.down.circle"))
        #expect(row?.keyEquivalent == nil)
        #expect(row?.help == "Looks for a newer version of Sorello")
    }

    /// While the updater is busy with a check of its own, the command cannot be chosen; it is still there.
    @Test func checkForUpdatesIsUnavailableWhileTheUpdaterIsBusy() {
        let row = Self.rows(.checkForUpdates(isEnabled: false)).first { $0.id == .updates }
        #expect(row?.title == "Check for Updates…")
        #expect(row?.isEnabled == false)
        #expect(row?.command == .checkForUpdates)
    }

    @Test func aVersionFoundUnaskedReadsUpdateAvailable() {
        let rows = Self.rows(.updateAvailable)
        #expect(Array(StatusMenuRowsTests.summary(rows).suffix(2)) == [
            "command checkForUpdates | Update Available…", "command quit | Quit Sorello | ⌘q",
        ])
        #expect(rows.filter { $0.id == .updates }.count == 1)
        #expect(rows.first { $0.id == .updates }?.isEnabled == true)
    }

    /// Choosing the row, in either form, asks the app layer to show the updater's window, and nothing else.
    @Test func choosingTheRowAsksForTheUpdatersWindow() {
        var asked: [String] = []
        let actions = StatusMenuActions(openSettings: { asked.append("settings") },
                                        checkForUpdates: { asked.append("updates") }, quit: { asked.append("quit") })
        actions.perform(.checkForUpdates)
        #expect(asked == ["updates"])
    }

    /// The model carries the row, and an open menu changes it in place when a check finds a version.
    @Test func theMenuFollowsTheUpdateRow() {
        let model = StatusMenuModel.sample()
        let menu = StatusMenuController(model: model)
        #expect(!menu.text.contains("Updat"))
        model.updates = .checkForUpdates(isEnabled: true)
        menu.update()
        #expect(menu.text.contains("Check for Updates…"))
        let item = menu.menu.items.first { $0.title == "Check for Updates…" }
        model.updates = .updateAvailable
        menu.update()
        #expect(menu.menu.items.first { $0.title == "Update Available…" } === item, "the same item, changed in place")
        #expect(menu.menu.items.last?.title == "Quit Sorello")
        model.updates = nil
        menu.update()
        #expect(!menu.menu.items.contains { $0.title.hasPrefix("Update") || $0.title.hasPrefix("Check for") })
    }

    /// The snapshot texts list the menu with each form of the row; the states without it are unchanged.
    @Test func theSnapshotTextsShowEachFormOfTheRow() {
        let texts = Dictionary(uniqueKeysWithValues: StatusMenuSnapshots.texts.map { ($0.name, $0.text) })
        #expect(texts["menu-updates"]?.contains("Check for Updates…") == true)
        #expect(texts["menu-update-available"]?.contains("Update Available…") == true)
        #expect(texts["menu-updates-checking"]?.contains("unavailable") == true)
        for (name, text) in texts where !name.contains("update") {
            #expect(!text.contains("Updat"), "\(name)")
        }
    }
}
