import SwiftUI

/// The main window's sections, in sidebar order.
public enum MainSection: CaseIterable, Hashable, Sendable {
    case general
    case shortcuts
    case dictionary
    case macros
    case runLog
    case about

    /// The section's name, in the sidebar.
    public var title: String {
        switch self {
        case .general: String(localized: "General")
        case .shortcuts: String(localized: "Shortcuts")
        case .dictionary: String(localized: "Dictionary")
        case .macros: String(localized: "Macros")
        case .runLog: String(localized: "Run Log")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "command"
        case .dictionary: "character.book.closed"
        case .macros: "text.bubble"
        case .runLog: "clock.arrow.circlepath"
        case .about: "info.circle"
        }
    }

    /// ⌘1 to ⌘6.
    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(Character(String((MainSection.allCases.firstIndex(of: self) ?? 0) + 1)))
    }
}

/// The main window's values: which section shows, and each section's model.
@Observable
public final class MainWindowModel {
    /// The section showing. The app layer sets it to open the window at a section.
    public var section: MainSection
    /// General's values.
    public let general: GeneralModel
    /// Shortcuts' values.
    public let shortcuts: ShortcutsModel
    /// Dictionary's values.
    public let dictionary: DictionaryModel
    /// Macros' values.
    public let macros: MacrosModel
    /// The Run Log's values.
    public let runLog: RunLogModel
    /// About's values.
    public let about: AboutModel

    /// The main window's values, opening at `section`.
    public init(section: MainSection = .general, general: GeneralModel, shortcuts: ShortcutsModel,
                dictionary: DictionaryModel, macros: MacrosModel, runLog: RunLogModel, about: AboutModel) {
        self.section = section
        self.general = general
        self.shortcuts = shortcuts
        self.dictionary = dictionary
        self.macros = macros
        self.runLog = runLog
        self.about = about
    }
}

/// The main window: a sidebar over the screen colour, and the chosen section's cards beside it. The sidebar's foot
/// carries the state line, so a problem is visible from every section.
public struct MainWindowView: View {
    @Bindable private var model: MainWindowModel

    /// The main window drawn from `model`.
    public init(model: MainWindowModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            Rectangle().fill(Theme.separator).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.screen)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .tint(Theme.ink)
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .general: GeneralScreen(model: model.general)
        case .shortcuts: ShortcutsScreen(model: model.shortcuts)
        case .dictionary: DictionaryScreen(model: model.dictionary)
        case .macros: MacrosScreen(model: model.macros)
        case .runLog: RunLogScreen(model: model.runLog)
        case .about: AboutScreen(model: model.about)
        }
    }
}

/// The sections as a list: arrow keys move through them, ⌘1 to ⌘6 jump to one, VoiceOver hears which is selected.
private struct Sidebar: View {
    @Bindable var model: MainWindowModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(MainSection.allCases, id: \.self) { section in
                SidebarItem(section: section, isSelected: model.section == section, listFocused: focused) {
                    model.section = section
                }
                .keyboardShortcut(section.keyEquivalent, modifiers: .command)
            }
            Spacer(minLength: 12)
            StatusLabel(model.general.status.line, font: .system(size: 11.5, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
        }
        .padding(.top, Metrics.titleBarClearance + 8)
        .padding(.horizontal, 10)
        .frame(width: Metrics.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let all = MainSection.allCases
            guard let index = all.firstIndex(of: model.section) else { return }
            switch direction {
            case .up where index > 0: model.section = all[index - 1]
            case .down where index < all.count - 1: model.section = all[index + 1]
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Sections"))
    }
}

private struct SidebarItem: View {
    let section: MainSection
    let isSelected: Bool
    let listFocused: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Theme.ink : Theme.secondaryInk)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected || hovering ? Theme.ink : Theme.secondaryInk)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Theme.selection : (hovering ? Theme.hover : .clear))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(isSelected && listFocused ? 0.5 : 0), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
