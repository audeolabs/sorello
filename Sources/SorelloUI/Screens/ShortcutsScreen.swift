import SwiftUI

/// What tapping Hold to Talk twice does, as the Shortcuts screen offers it. The app layer maps it to the session's
/// setting; SorelloUI only names the choices and says what each does.
nonisolated public enum DoubleTapChoice: CaseIterable, Hashable, Sendable {
    /// A dictation that goes on with no key held until Hold to Talk is tapped once more. The default.
    case handsFree
    /// A held dictation whose text starts with the prompt tag.
    case prompt
    /// Nothing special.
    case off

    /// The choice's name in the pop-up.
    public var title: String {
        switch self {
        case .handsFree: String(localized: "Dictate hands-free", comment: "Double tap choice")
        case .prompt: String(localized: "Start a prompt", comment: "Double tap choice")
        case .off: String(localized: "Do nothing", comment: "Double tap choice")
        }
    }

    /// One sentence that says what the choice does, for VoiceOver.
    public var explanation: String {
        switch self {
        case .handsFree:
            String(localized: "Tap Hold to Talk twice to start. Tap it once more to stop and paste.")
        case .prompt:
            String(localized: "Tap Hold to Talk, then hold it as you speak. The text starts with a tag, so an AI agent knows it was dictated.")
        case .off:
            String(localized: "Tapping Hold to Talk twice does nothing.")
        }
    }
}

/// The Shortcuts screen's values.
@Observable
public final class ShortcutsModel {
    /// Each action's recorder.
    public var recorders: [ShortcutKind: ShortcutRecorderState]
    /// What tapping Hold to Talk twice does.
    public var doubleTap: DoubleTapChoice
    /// The tag a prompt puts before the text, as the text rules write it.
    public var promptTag: String
    /// Record, cancel and clear a shortcut.
    public var recorderActions: ShortcutRecorderActions
    /// The user chose what the double tap does; the model already shows the new value.
    public var setDoubleTap: (DoubleTapChoice) -> Void
    /// Open the Keyboard pane of System Settings, where the fn key's own action is chosen.
    public var openKeyboardSettings: () -> Void

    /// The Shortcuts screen's values.
    public init(recorders: [ShortcutKind: ShortcutRecorderState], doubleTap: DoubleTapChoice, promptTag: String,
                recorderActions: ShortcutRecorderActions = ShortcutRecorderActions(),
                setDoubleTap: @escaping (DoubleTapChoice) -> Void = { _ in },
                openKeyboardSettings: @escaping () -> Void = {}) {
        self.recorders = recorders
        self.doubleTap = doubleTap
        self.promptTag = promptTag
        self.recorderActions = recorderActions
        self.setDoubleTap = setDoubleTap
        self.openKeyboardSettings = openKeyboardSettings
    }

    /// A recorder's state; an action the app layer has not described reads as unset.
    public func recorder(_ kind: ShortcutKind) -> ShortcutRecorderState {
        recorders[kind] ?? ShortcutRecorderState(keys: nil)
    }

    /// The user chose what the double tap does: show it, and report it.
    public func choose(_ choice: DoubleTapChoice) {
        doubleTap = choice
        setDoubleTap(choice)
    }

    /// Whether the prompt tag is in use, which is only when the double tap starts a prompt.
    var usesTag: Bool { doubleTap == .prompt }

    /// Whether any shortcut uses fn, which has a system action of its own.
    var usesFunctionKey: Bool {
        recorders.values.contains { $0.keys?.modifiers.contains(.function) == true }
    }
}

/// Shortcuts: a recorder for each action, what the double tap does with the prompt's tag, and a note about the fn
/// key.
public struct ShortcutsScreen: View {
    @Bindable private var model: ShortcutsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The Shortcuts screen drawn from `model`.
    public init(model: ShortcutsModel) {
        self.model = model
    }

    public var body: some View {
        ScreenPage(String(localized: "Shortcuts")) {
            CardGroup(String(localized: "Dictation")) {
                Card {
                    ForEach(ShortcutKind.allCases, id: \.self) { kind in
                        ShortcutRecorderRow(kind, state: model.recorder(kind), actions: model.recorderActions)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.recorders)
            }
            CardGroup(String(localized: "Double tap")) {
                Card(dividerInset: Metrics.wordsInset) {
                    SettingRow(String(localized: "Double-tap Hold to Talk"), symbol: "hand.tap") {
                        DoubleTapPicker(model: model)
                    }
                    SettingRow(String(localized: "Tag"), symbol: "tag") {
                        Text(verbatim: model.promptTag)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.controlFill))
                            .accessibilityLabel(String(localized: "Tag: \(model.promptTag)"))
                    }
                    .opacity(model.usesTag ? 1 : 0.5)
                }
            }
            if model.usesFunctionKey {
                FunctionKeyNote(openKeyboardSettings: model.openKeyboardSettings)
            }
        }
    }
}

/// The double tap's three choices as a pop-up, like the General screen's microphone.
private struct DoubleTapPicker: View {
    @Bindable var model: ShortcutsModel

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { model.doubleTap }, set: { model.choose($0) })) {
                ForEach(DoubleTapChoice.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            MenuLabel(title: model.doubleTap.title)
        }
        .menuStyle(.button)
        .buttonStyle(MenuLabelStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "Double-tap Hold to Talk"))
        .accessibilityValue(model.doubleTap.title)
        .accessibilityHint(model.doubleTap.explanation)
    }
}

/// The fn key also has a system action. Sorello never changes system settings; this says how to, and opens the pane.
struct FunctionKeyNote: View {
    let openKeyboardSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.glyphGap) {
            RowGlyph("globe")
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 8) {
                Text("If fn opens the emoji picker or changes the input source")
                    .font(.rowTitle)
                    .foregroundStyle(Theme.ink)
                Text("In System Settings, Keyboard, set what the fn or Globe key does to “Do Nothing”.")
                    .font(.rowDetail)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Open Keyboard Settings"), action: openKeyboardSettings)
                    .buttonStyle(PrimaryButtonStyle(size: .compact))
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(Metrics.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
    }
}
