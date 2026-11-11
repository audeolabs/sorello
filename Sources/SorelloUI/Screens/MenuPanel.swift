import SwiftUI

/// What the menu panel does when its controls are used. The app layer supplies each.
public struct MenuPanelActions {
    /// Put the last dictation on the clipboard.
    public var copyLastDictation: () -> Void
    /// Load the speech model again after a failure.
    public var retryModel: () -> Void
    /// Open the main window's General screen, where a missing permission is fixed.
    public var openGeneral: () -> Void
    /// Open the main window at Dictionary.
    public var openDictionary: () -> Void
    /// Open the main window at the Run Log.
    public var openRunLog: () -> Void
    /// Open the main window, at the section it last showed.
    public var openSettings: () -> Void
    /// Quit the app.
    public var quit: () -> Void

    /// Actions that each do nothing unless given.
    public init(copyLastDictation: @escaping () -> Void = {}, retryModel: @escaping () -> Void = {},
                openGeneral: @escaping () -> Void = {}, openDictionary: @escaping () -> Void = {},
                openRunLog: @escaping () -> Void = {}, openSettings: @escaping () -> Void = {},
                quit: @escaping () -> Void = {}) {
        self.copyLastDictation = copyLastDictation
        self.retryModel = retryModel
        self.openGeneral = openGeneral
        self.openDictionary = openDictionary
        self.openRunLog = openRunLog
        self.openSettings = openSettings
        self.quit = quit
    }
}

/// The menu panel's values. The app layer keeps them current.
@Observable
public final class MenuPanelModel {
    /// The app's name as installed, from the bundle.
    public var appName: String
    /// The model and permissions, for the state line.
    public var status: AppStatus
    /// The shortcuts, in the order of `ShortcutKind.allCases`. An unset one shows "Not set".
    public var shortcuts: [ShortcutKind: KeyCombo]
    /// The last dictation's text, for Paste Again and copying; nil when there is none.
    public var lastDictation: String?
    /// What the panel asks of the app layer.
    public var actions: MenuPanelActions

    /// The menu panel's values.
    public init(appName: String, status: AppStatus, shortcuts: [ShortcutKind: KeyCombo], lastDictation: String?,
                actions: MenuPanelActions = MenuPanelActions()) {
        self.appName = appName
        self.status = status
        self.shortcuts = shortcuts
        self.lastDictation = lastDictation
        self.actions = actions
    }
}

/// The panel shown from the menu-bar item: the state line, the shortcuts as key caps, the last dictation with a copy
/// button, then the way into the app. About 300 points wide; it sizes its own height.
public struct MenuPanelView: View {
    private let model: MenuPanelModel
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The menu panel drawn from `model`.
    public init(model: MenuPanelModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            shortcuts
            lastDictation
            VStack(spacing: 0) {
                MenuRow(String(localized: "Dictionary"), symbol: "character.book.closed", action: model.actions.openDictionary)
                MenuRow(String(localized: "Run Log"), symbol: "clock.arrow.circlepath", action: model.actions.openRunLog)
                MenuRow(String(localized: "Settings…"), symbol: "gearshape", keys: "⌘,", action: model.actions.openSettings)
                    .keyboardShortcut(",", modifiers: .command)
                Rectangle().fill(Theme.separator).frame(height: 1).padding(.vertical, 5).padding(.horizontal, 10)
                MenuRow(String(localized: "Quit \(model.appName)"), symbol: "power", keys: "⌘Q", action: model.actions.quit)
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(10)
        .frame(width: WindowChrome.menuPanelWidth)
        .background(Theme.screen)
    }

    // MARK: Parts

    private var header: some View {
        let line = model.status.line
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.appName)
                    .font(.display(22, relativeTo: .title2))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                StatusLabel(line)
            }
            Spacer(minLength: 8)
            if let remedy = line.remedy {
                Button(remedy.title) {
                    remedy == .retryModel ? model.actions.retryModel() : model.actions.openGeneral()
                }
                .buttonStyle(PrimaryButtonStyle(size: .compact))
                .accessibilityHint(remedy.hint)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var shortcuts: some View {
        VStack(spacing: 0) {
            ForEach(ShortcutKind.allCases, id: \.self) { kind in
                HStack {
                    Text(kind.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(model.shortcuts[kind] == nil ? Theme.secondaryInk : Theme.ink)
                    Spacer(minLength: 8)
                    KeyCaps(model.shortcuts[kind], size: .small)
                }
                .frame(minHeight: 30)
                .padding(.horizontal, 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(kind.title)
                .accessibilityValue(model.shortcuts[kind]?.spokenLabel ?? String(localized: "Not set"))
            }
        }
        .padding(.vertical, 4)
        .cardSurface(radius: 10)
    }

    @ViewBuilder
    private var lastDictation: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text("Last dictation")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
                Spacer()
                if model.lastDictation != nil {
                    Button {
                        model.actions.copyLastDictation()
                        flashCopied()
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(IconButtonStyle(diameter: 24))
                    .accessibilityLabel(copied ? String(localized: "Copied") : String(localized: "Copy last dictation"))
                }
            }
            Group {
                if let text = model.lastDictation {
                    Text(text)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .truncationMode(.tail)
                } else {
                    Text("Nothing dictated yet.")
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            .font(.system(size: 12.5))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .cardSurface(radius: 10)
        .accessibilityElement(children: .contain)
    }

    private func flashCopied() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { copied = false }
        }
    }
}

/// A menu item: a glyph, its words, and the keys that do the same, lit under the pointer as a menu's items are.
private struct MenuRow: View {
    let title: String
    let symbol: String
    let keys: String?
    let action: () -> Void

    init(_ title: String, symbol: String, keys: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.keys = keys
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 8)
                if let keys {
                    Text(keys)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryInk)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(MenuRowStyle())
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRowBody(configuration: configuration)
    }
}

private struct MenuRowBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering || isFocused ? Theme.selection : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}
