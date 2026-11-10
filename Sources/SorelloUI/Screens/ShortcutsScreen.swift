import SwiftUI

/// The Shortcuts screen's values.
@Observable
public final class ShortcutsModel {
    public var recorders: [ShortcutKind: ShortcutRecorderState]
    /// Double-tapping Hold to Talk starts a dictation whose text begins with the prompt tag.
    public var promptModeEnabled: Bool
    /// The tag prompt mode puts before the text, as the text rules write it.
    public var promptTag: String
    public var recorderActions: ShortcutRecorderActions
    public var setPromptMode: (Bool) -> Void
    /// Open the Keyboard pane of System Settings, where the fn key's own action is chosen.
    public var openKeyboardSettings: () -> Void

    public init(recorders: [ShortcutKind: ShortcutRecorderState], promptModeEnabled: Bool, promptTag: String,
                recorderActions: ShortcutRecorderActions = ShortcutRecorderActions(),
                setPromptMode: @escaping (Bool) -> Void = { _ in }, openKeyboardSettings: @escaping () -> Void = {}) {
        self.recorders = recorders
        self.promptModeEnabled = promptModeEnabled
        self.promptTag = promptTag
        self.recorderActions = recorderActions
        self.setPromptMode = setPromptMode
        self.openKeyboardSettings = openKeyboardSettings
    }

    /// A recorder's state; an action the app layer has not described reads as unset.
    public func recorder(_ kind: ShortcutKind) -> ShortcutRecorderState {
        recorders[kind] ?? ShortcutRecorderState(keys: nil)
    }

    /// Whether any shortcut uses fn, which has a system action of its own.
    var usesFunctionKey: Bool {
        recorders.values.contains { $0.keys?.modifiers.contains(.function) == true }
    }
}

/// Shortcuts: a recorder for each action, prompt mode with its tag, and a note about the fn key.
public struct ShortcutsScreen: View {
    @Bindable private var model: ShortcutsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: ShortcutsModel) {
        self.model = model
    }

    public var body: some View {
        ScreenPage(String(localized: "Shortcuts"),
                   subtitle: String(localized: "They work in any app. Escape cancels a dictation.")) {
            CardGroup(String(localized: "Dictation")) {
                Card {
                    ForEach(ShortcutKind.allCases, id: \.self) { kind in
                        ShortcutRecorderRow(kind, state: model.recorder(kind), actions: model.recorderActions)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.recorders)
            } footer: {
                Text("While a recorder is listening, no shortcut starts a dictation.")
            }
            CardGroup(String(localized: "Prompt mode")) {
                Card(dividerInset: Metrics.wordsInset) {
                    ToggleRow(String(localized: "Double-tap for a prompt"),
                              detail: String(localized: "Double-tap Hold to Talk, then hold. The text starts with a tag, so an AI agent knows it was dictated."),
                              symbol: "text.bubble",
                              isOn: Binding(get: { model.promptModeEnabled },
                                            set: { value in
                                                model.promptModeEnabled = value
                                                model.setPromptMode(value)
                                            }))
                    SettingRow(String(localized: "Tag"), symbol: "tag") {
                        Text(verbatim: model.promptTag)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.controlFill))
                            .accessibilityLabel(String(localized: "Tag: \(model.promptTag)"))
                    }
                    .opacity(model.promptModeEnabled ? 1 : 0.5)
                }
            }
            if model.usesFunctionKey {
                FunctionKeyNote(openKeyboardSettings: model.openKeyboardSettings)
            }
        }
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
                Text("In System Settings, Keyboard, set what the fn or 🌐 key does to “Do Nothing”.")
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
