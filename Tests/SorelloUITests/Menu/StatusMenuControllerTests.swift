import AppKit
import DesignCore
import Testing
@testable import SorelloUI

/// ARCHITECTURE.md, section 8, "Windows", the menu: the `NSMenu` the menu-bar item opens, built from the rows, and
/// kept current while it is open. Nothing here opens a menu or puts anything on the screen.
@MainActor
@Suite struct StatusMenuControllerTests {
    /// A menu sends an item's action through the application, so there has to be one. The app always has it; a test
    /// process has it only once something has made it, which another suite may or may not have done by now.
    init() {
        _ = NSApplication.shared
    }

    static let failed = AppStatus(model: .failed(.couldNotLoad), microphone: .granted, accessibility: .granted)
    static let preparing = AppStatus(model: .preparing, microphone: .granted, accessibility: .granted)

    /// The model's actions, each reporting its command.
    static func reporting(into reported: @escaping (StatusMenuCommand) -> Void) -> StatusMenuActions {
        StatusMenuActions(
            copyLastDictation: { reported(.copyLastDictation) }, transcribeFile: { reported(.transcribeFile) },
            retryModel: { reported(.retryModel) },
            openGeneral: { reported(.openGeneral) }, openShortcuts: { reported(.openShortcuts) },
            openDictionary: { reported(.openDictionary) }, openRunLog: { reported(.openRunLog) },
            openSettings: { reported(.openSettings) }, quit: { reported(.quit) })
    }

    @Test func theMenuHoldsTheRowsInOrder() throws {
        let model = StatusMenuModel.sample()
        let controller = StatusMenuController(model: model)
        let items = controller.menu.items
        #expect(items.count == model.rows.count)
        #expect(items.map(\.title) == model.rows.map { $0.kind == .separator ? "" : $0.title })
        #expect(items.indices.filter { items[$0].isSeparatorItem } == [1, 6, 9])
        #expect(items.filter(\.isSectionHeader).map(\.title) == ["Shortcuts"])
        #expect(items.indices.filter { items[$0].isSectionHeader } == [2])
        // Copy Last Dictation and Transcribe File… are a group of their own; the state line is the only item that is
        // not a command.
        #expect(items[7].title == "Copy Last Dictation" && items[8].title == "Transcribe File…")
        #expect(items.filter { $0.action == nil && !$0.isSeparatorItem && !$0.isSectionHeader }.map(\.title)
            == ["Ready"])
        // The system draws every row: no views, no attributed titles.
        #expect(items.allSatisfy { $0.view == nil && $0.attributedTitle == nil })
    }

    @Test func settingsAndQuitHaveRealKeyEquivalentsAndNothingElseDoes() throws {
        let controller = StatusMenuController(model: .sample())
        let items = controller.menu.items
        let settings = try #require(items.first { $0.title == "Settings…" })
        let quit = try #require(items.first { $0.title == "Quit Sorello" })
        #expect(settings.keyEquivalent == "," && settings.keyEquivalentModifierMask == .command)
        #expect(quit.keyEquivalent == "q" && quit.keyEquivalentModifierMask == .command)
        #expect(items.filter { !$0.keyEquivalent.isEmpty }.count == 2)
    }

    /// Each shortcut's keys sit at the trailing edge of its row, the same way for all three.
    @Test func theShortcutsKeysAreAtTheTrailingEdge() {
        let controller = StatusMenuController(model: .sample())
        let shortcuts = controller.menu.items.filter { ShortcutKind.allCases.map(\.title).contains($0.title) }
        #expect(shortcuts.map { $0.badge?.stringValue } == ["fn", "⌃⌥Space", "Not set"])
        #expect(controller.menu.items.filter { $0.badge != nil }.count == 3)
    }

    @Test func onlyCommandsThatCanBeUsedAreEnabled() {
        let controller = StatusMenuController(model: .sample(status: Self.failed, hasLastDictation: false))
        let enabled = controller.menu.items.filter { $0.isEnabled && !$0.isSeparatorItem && !$0.isSectionHeader }
        #expect(enabled.map(\.title) == ["Retry", "Hold to Talk", "Tap to Toggle", "Paste Again", "Transcribe File…",
                                         "Dictionary", "Run Log", "Settings…", "Quit Sorello"])
        let state = controller.menu.items[0], copy = controller.menu.items[8]
        #expect(state.title == "Speech model unavailable" && !state.isEnabled)
        #expect(copy.title == "Copy Last Dictation" && !copy.isEnabled)
    }

    @Test func choosingEachCommandReportsItsActionOnce() {
        var reported: [StatusMenuCommand] = []
        let model = StatusMenuModel.sample(status: Self.failed)
        model.actions = Self.reporting { reported.append($0) }
        let controller = StatusMenuController(model: model)
        for index in controller.menu.items.indices {
            controller.menu.performActionForItem(at: index)
        }
        #expect(reported == [.retryModel, .openShortcuts, .openShortcuts, .openShortcuts, .copyLastDictation,
                             .transcribeFile, .openDictionary, .openRunLog, .openSettings, .quit])
    }

    @Test func aMissingPermissionsRemedyOpensGeneral() throws {
        var reported: [StatusMenuCommand] = []
        let model = StatusMenuModel.sample(status: AppStatus(model: .ready, microphone: .granted,
                                                             accessibility: .missing))
        model.actions = Self.reporting { reported.append($0) }
        let controller = StatusMenuController(model: model)
        let fix = try #require(controller.menu.items.firstIndex { $0.title == "Fix…" })
        #expect(fix == 1)
        controller.menu.performActionForItem(at: fix)
        #expect(reported == [.openGeneral])
    }

    @Test func copyWithNothingDictatedReportsNothing() throws {
        var reported: [StatusMenuCommand] = []
        let model = StatusMenuModel.sample(hasLastDictation: false)
        model.actions = Self.reporting { reported.append($0) }
        let controller = StatusMenuController(model: model)
        let copy = try #require(controller.menu.items.firstIndex { $0.title == "Copy Last Dictation" })
        controller.menu.performActionForItem(at: copy)
        #expect(reported.isEmpty)
    }

    /// The menu is made from the values each time it opens.
    @Test func theMenuIsMadeAgainWhenItOpens() {
        let model = StatusMenuModel.sample(status: Self.preparing)
        let controller = StatusMenuController(model: model)
        model.status = .sampleReady
        model.hasLastDictation = false
        controller.menuNeedsUpdate(controller.menu)
        #expect(controller.menu.items[0].title == "Ready")
        #expect(controller.menu.items.first { $0.title == "Copy Last Dictation" }?.isEnabled == false)
    }

    /// While the menu is open, a change in the values changes its rows where they are, without closing it: a
    /// dictation arriving makes Copy available, and clearing the Run Log makes it unavailable again.
    @Test func anOpenMenuChangesInPlace() async throws {
        let model = StatusMenuModel.sample(status: Self.preparing, hasLastDictation: false)
        let controller = StatusMenuController(model: model)
        let menu = controller.menu
        controller.menuNeedsUpdate(menu)
        controller.menuWillOpen(menu)
        let state = menu.items[0]
        let copy = try #require(menu.items.first { $0.title == "Copy Last Dictation" })
        #expect(!copy.isEnabled)

        model.status = .sampleReady
        await until { state.title == "Ready" }
        #expect(menu.items[0] === state)

        let items = menu.items
        model.hasLastDictation = true
        await until { copy.isEnabled }
        #expect(menu.items.elementsEqual(items, by: ===))
        model.hasLastDictation = false
        await until { !copy.isEnabled }
        #expect(menu.items.elementsEqual(items, by: ===))
        model.hasLastDictation = true
        await until { copy.isEnabled }

        model.shortcuts[.pasteAgain] = KeyCombo(modifiers: [.option(.right)])
        await until { menu.items.contains { $0.badge?.stringValue == "Right ⌥" } }

        // A remedy appears under the state line and goes again, and nothing else moves.
        let before = menu.items
        model.status = Self.failed
        await until { menu.items.count == before.count + 1 }
        #expect(menu.items[1].title == "Retry")
        #expect(menu.items[0] === state && Array(menu.items[2...]).elementsEqual(before[1...], by: ===))
        model.status = .sampleReady
        await until { menu.items.count == before.count }
        #expect(menu.items.elementsEqual(before, by: ===))
        controller.menuDidClose(menu)
    }

    /// The dot is the state row's own image, in the state's colour, not a template the menu would tint.
    @Test(arguments: [(StatusLine.Indicator.ready, Palette.aurora), (.preparing, Palette.glacier),
                      (.neutral, Palette.ink.blended(alpha: Palette.neutralDotAlpha, over: Palette.screen))])
    func theStateDotIsTheStatesColour(indicator: StatusLine.Indicator, colour: RGB) throws {
        let image = StatusMenuController.image(for: .indicator(indicator))
        #expect(!image.isTemplate)
        let pixels = try Pixels(image)
        let centre = pixels[pixels.width / 2, pixels.height / 2]
        #expect(centre.isClose(to: colour))
        #expect(pixels[0, 0].alpha == 0)
    }

    /// A problem is marked by an ember warning symbol, never a dot.
    @Test func aProblemIsAnEmberSymbol() throws {
        let image = StatusMenuController.image(for: .indicator(.problem))
        #expect(!image.isTemplate)
        let pixels = try Pixels(image)
        #expect(pixels.all.contains { $0.isClose(to: Palette.ember) })
    }

    @Test func voiceOverHearsEachShortcutInWords() {
        let controller = StatusMenuController(model: .sample())
        let labels = controller.menu.items.filter { ShortcutKind.allCases.map(\.title).contains($0.title) }
            .map { $0.accessibilityLabel() }
        #expect(labels == ["Hold to Talk, Function", "Tap to Toggle, Control Option Space", "Paste Again, Not set"])
        #expect(controller.menu.items[0].accessibilityLabel() == "Ready")
    }

    /// The menu as text, for review: every row on a line of its own, in order, with what it is, its glyph, its title
    /// and what sits at its trailing edge.
    @Test func theTextListsEveryRow() {
        let ready = StatusMenuController(model: .sample()).text
        #expect(Self.fields(ready) == [
            ["not a command", "aurora dot", "Ready"],
            ["separator"],
            ["heading", "Shortcuts"],
            ["command", "Hold to Talk", "fn"],
            ["command", "Tap to Toggle", "⌃⌥Space"],
            ["command", "Paste Again", "Not set"],
            ["separator"],
            ["command", "doc.on.doc", "Copy Last Dictation"],
            ["command", "waveform", "Transcribe File…"],
            ["separator"],
            ["command", "character.book.closed", "Dictionary"],
            ["command", "clock.arrow.circlepath", "Run Log"],
            ["command", "gearshape", "Settings…", "⌘,"],
            ["command", "power", "Quit Sorello", "⌘Q"],
        ])
        let failed = Self.fields(
            StatusMenuController(model: .sample(status: Self.failed, hasLastDictation: false)).text)
        #expect(Array(failed.prefix(2)) == [["not a command", "ember warning", "Speech model unavailable"],
                                            ["command", "Retry"]])
        #expect(failed.contains(["unavailable", "doc.on.doc", "Copy Last Dictation"]))
        // Titles start in one column, so the list reads as a table.
        let titles = ["Ready", "Shortcuts", "Hold to Talk", "Tap to Toggle", "Paste Again", "Copy Last Dictation",
                      "Transcribe File…", "Dictionary", "Run Log", "Settings…", "Quit Sorello"]
        let rows = ready.split(separator: "\n").filter { $0 != "separator" }
        let starts = zip(rows, titles).compactMap { row, title in
            row.range(of: title).map { row.distance(from: row.startIndex, to: $0.lowerBound) }
        }
        #expect(starts.count == titles.count && Set(starts).count == 1)
        #expect(ready.hasSuffix("\n") && !ready.contains(" \n"))
    }

    /// The snapshot tool writes the menu's states as text, in place of pictures of it, the model's download
    /// included, and then the menu of a build that can update itself, with each form of its update row.
    @Test func theSnapshotsListTheStatesAsText() {
        let texts = StatusMenuSnapshots.texts
        #expect(texts.map(\.name) == ["menu-ready", "menu-preparing", "menu-microphone-needed",
                                      "menu-accessibility-needed", "menu-model-failed", "menu-paused",
                                      "menu-model-not-downloaded", "menu-model-downloading", "menu-model-no-build",
                                      "menu-updates", "menu-updates-checking", "menu-update-available"])
        #expect(texts.allSatisfy { !$0.text.isEmpty })
        #expect(!SnapshotCatalog.all.contains { $0.name.hasPrefix("menu") })
    }

    static func fields(_ text: String) -> [[String]] {
        text.split(separator: "\n").map { line in line.split(separator: "  ").map { $0.trimmingCharacters(in: .whitespaces) } }
    }

    private func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// An image drawn into sRGB pixels, to read the colours it shows.
@MainActor
private struct Pixels {
    struct Pixel {
        var red, green, blue, alpha: Double

        func isClose(to rgb: RGB) -> Bool {
            alpha > 0.95 && abs(red - rgb.red) < 0.03 && abs(green - rgb.green) < 0.03 && abs(blue - rgb.blue) < 0.03
        }
    }

    let width: Int, height: Int
    private let bytes: [UInt8]

    init(_ image: NSImage) throws {
        width = Int(image.size.width * 2)
        height = Int(image.size.height * 2)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(context.data)
        bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    subscript(x: Int, y: Int) -> Pixel {
        let offset = (y * width + x) * 4
        let alpha = Double(bytes[offset + 3]) / 255
        guard alpha > 0 else { return Pixel(red: 0, green: 0, blue: 0, alpha: 0) }
        return Pixel(red: Double(bytes[offset]) / 255 / alpha, green: Double(bytes[offset + 1]) / 255 / alpha,
                     blue: Double(bytes[offset + 2]) / 255 / alpha, alpha: alpha)
    }

    var all: [Pixel] {
        (0..<height).flatMap { y in (0..<width).map { x in self[x, y] } }
    }
}
