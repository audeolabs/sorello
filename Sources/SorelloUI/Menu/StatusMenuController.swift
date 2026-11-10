import AppKit
import DesignCore
import Observation

/// The menu-bar item's menu (ARCHITECTURE.md, section 8, "Windows"): an ordinary `NSMenu`, which the system opens,
/// places, highlights, tracks and closes, in its own material and in the menu bar's light or dark appearance. This
/// gives it items made from `StatusMenuModel.rows` and nothing else: no views, no attributed titles, no colours but
/// the state's dot.
///
/// The menu is made from the values each time it opens. While it is open, a change in the values changes its items
/// where they are: an item keeps its identity, and only a remedy that comes or goes is inserted or removed.
public final class StatusMenuController: NSObject, NSMenuDelegate {
    /// The menu, for the status item.
    public let menu = NSMenu()
    private let model: StatusMenuModel
    /// Each row as it is shown, with its item, in the menu's order.
    private var shown: [(row: StatusMenuRow, item: NSMenuItem)] = []
    private var isOpen = false
    private var observing = false

    /// A menu showing `model`, and reporting its commands to `model.actions`.
    public init(model: StatusMenuModel) {
        self.model = model
        super.init()
        // Each item's own `isEnabled` says whether it can be chosen; the menu does not work it out from the target.
        menu.autoenablesItems = false
        menu.delegate = self
        update()
    }

    /// Makes the items match the values now.
    public func update() {
        let rows = model.rows
        let wanted = Set(rows.map(\.id))
        for entry in shown where !wanted.contains(entry.row.id) {
            menu.removeItem(entry.item)
        }
        var kept: [StatusMenuRow.ID: (row: StatusMenuRow, item: NSMenuItem)] = [:]
        for entry in shown where wanted.contains(entry.row.id) {
            kept[entry.row.id] = entry
        }
        var next: [(row: StatusMenuRow, item: NSMenuItem)] = []
        for (index, row) in rows.enumerated() {
            let item: NSMenuItem
            if let entry = kept[row.id] {
                item = entry.item
                if entry.row != row { apply(row, to: item) }
                if menu.index(of: item) != index {
                    menu.removeItem(item)
                    menu.insertItem(item, at: index)
                }
            } else {
                item = Self.item(for: row)
                apply(row, to: item)
                menu.insertItem(item, at: index)
            }
            next.append((row, item))
        }
        shown = next
    }

    // MARK: NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        update()
    }

    public func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        observe()
    }

    public func menuDidClose(_ menu: NSMenu) {
        isOpen = false
    }

    /// While the menu is open, updates it after each change to the values it was made from.
    private func observe() {
        guard isOpen, !observing else { return }
        observing = true
        withObservationTracking { update() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                observing = false
                observe()
            }
        }
    }

    // MARK: Items

    private static func item(for row: StatusMenuRow) -> NSMenuItem {
        switch row.kind {
        case .separator: .separator()
        case .heading: .sectionHeader(title: row.title)
        case .information, .command: NSMenuItem()
        }
    }

    private func apply(_ row: StatusMenuRow, to item: NSMenuItem) {
        switch row.kind {
        case .separator:
            return
        case .heading:
            item.title = row.title
            return
        case .information, .command:
            break
        }
        item.title = row.title
        item.image = row.image.map(Self.image(for:))
        if #available(macOS 27, *) {
            // The state's dot carries the state, and the glyphs are part of how the menu reads; from macOS 27 AppKit
            // hides a menu item's image unless asked to show it.
            item.preferredImageVisibility = row.image == nil ? .automatic : .visible
        }
        item.badge = row.trailing.map { NSMenuItemBadge(string: $0) }
        item.keyEquivalent = row.keyEquivalent ?? ""
        item.keyEquivalentModifierMask = row.keyEquivalent == nil ? [] : .command
        item.target = row.command == nil ? nil : self
        item.action = row.command == nil ? nil : #selector(choose(_:))
        item.isEnabled = row.isEnabled
        item.toolTip = row.help
        item.setAccessibilityLabel(row.accessibilityLabel)
        item.setAccessibilityHelp(row.help)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let row = shown.first(where: { $0.item === sender })?.row, row.isEnabled,
              let command = row.command else { return }
        model.actions.perform(command)
    }

    /// The glyph for `image`. A symbol is a template, drawn in the menu's text colour. The state's mark is drawn in
    /// the state's colour, in light and dark menus alike: a dot 8 points across, or the ember warning symbol for a
    /// problem.
    static func image(for image: StatusMenuRow.Image) -> NSImage {
        let size = CGSize(width: 14, height: 14)
        switch image {
        case .symbol(let name):
            return NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage(size: size)
        case .indicator(.problem):
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(Palette.ember)]))
            let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            return NSImage(size: size, flipped: false) { bounds in
                guard let symbol else { return false }
                let fit = min(bounds.width / symbol.size.width, bounds.height / symbol.size.height, 1)
                let drawn = CGSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
                symbol.draw(in: CGRect(x: bounds.midX - drawn.width / 2, y: bounds.midY - drawn.height / 2,
                                       width: drawn.width, height: drawn.height))
                return true
            }
        case .indicator(let indicator):
            let colour = NSColor(Self.dotColour(indicator))
            return NSImage(size: size, flipped: false) { bounds in
                colour.setFill()
                NSBezierPath(ovalIn: CGRect(x: bounds.midX - 4, y: bounds.midY - 4, width: 8, height: 8)).fill()
                return true
            }
        }
    }

    /// The dot's colour as the windows show it: aurora when ready, glacier while preparing, and for a state that is
    /// neither the grey the windows' neutral dot makes on their dark screen, which reads on a light menu too.
    private static func dotColour(_ indicator: StatusLine.Indicator) -> RGB {
        switch indicator {
        case .ready: Palette.aurora
        case .preparing: Palette.glacier
        case .neutral, .problem: Palette.ink.blended(alpha: Palette.neutralDotAlpha, over: Palette.screen)
        }
    }

    // MARK: Text

    /// The menu as text, for review in place of a picture the system alone can draw: every item on a line of its
    /// own, in order, saying what it is (heading, separator, command, unavailable or not a command), its glyph, its
    /// title and what sits at its trailing edge (its keys, or its key equivalent). Columns are aligned with spaces.
    public var text: String {
        let lines: [[String]] = shown.map { row, item in
            if item.isSeparatorItem { return ["separator"] }
            let role = item.isSectionHeader ? "heading"
                : item.action == nil ? "not a command"
                : item.isEnabled ? "command" : "unavailable"
            let trailing = item.badge?.stringValue ?? Self.keyEquivalentLabel(item)
            return [role, row.image.map(Self.describe) ?? "", item.title, trailing]
        }
        let widths = (0..<3).map { column in lines.map { $0.count > column ? $0[column].count : 0 }.max() ?? 0 }
        return lines.map { fields in
            let line = fields.enumerated().map { column, field in
                column < 3 ? field + String(repeating: " ", count: widths[column] + 2 - field.count) : field
            }.joined()
            return String(line.reversed().drop(while: \.isWhitespace).reversed())
        }.joined(separator: "\n") + "\n"
    }

    private static func describe(_ image: StatusMenuRow.Image) -> String {
        switch image {
        case .symbol(let name): name
        case .indicator(.ready): "aurora dot"
        case .indicator(.preparing): "glacier dot"
        case .indicator(.neutral): "grey dot"
        case .indicator(.problem): "ember warning"
        }
    }

    private static func keyEquivalentLabel(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let mask = item.keyEquivalentModifierMask
        let modifiers = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { mask.contains($0.0) }.map(\.1).joined()
        return modifiers + item.keyEquivalent.uppercased()
    }
}
