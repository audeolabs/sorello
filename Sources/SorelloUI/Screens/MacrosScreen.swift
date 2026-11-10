import SwiftUI

/// What the Macros screen asks of the app layer, which keeps the macros.
public struct MacrosActions {
    /// Checks a macro as the text rules would; nil when it can be saved. `id` is the macro being edited, or nil for
    /// a new one, so a macro is not a duplicate of itself.
    public var validate: (_ phrase: String, _ text: String, _ id: String?) -> MacroProblem?
    /// Saves a new macro (nil `id`) or replaces one. Returns why it was refused, or nil.
    public var save: (_ id: String?, _ phrase: String, _ text: String) -> MacroProblem?
    public var delete: (_ id: String) -> Void

    public init(validate: @escaping (String, String, String?) -> MacroProblem? = { _, _, _ in nil },
                save: @escaping (String?, String, String) -> MacroProblem? = { _, _, _ in nil },
                delete: @escaping (String) -> Void = { _ in }) {
        self.validate = validate
        self.save = save
        self.delete = delete
    }
}

/// A macro open for editing.
public struct MacroDraft: Equatable, Sendable {
    /// The macro being edited, or nil for a new one.
    public var id: String?
    public var phrase: String
    public var text: String

    public init(id: String? = nil, phrase: String = "", text: String = "") {
        self.id = id
        self.phrase = phrase
        self.text = text
    }
}

/// The Macros screen's values.
@Observable
public final class MacrosModel {
    public var macros: [MacroItem]
    /// The macro open in the editor, if any.
    public var editing: MacroDraft?
    /// Why the last save was refused, until the editor changes.
    public var refusal: MacroProblem?
    public var actions: MacrosActions

    public init(macros: [MacroItem], editing: MacroDraft? = nil, actions: MacrosActions = MacrosActions()) {
        self.macros = macros
        self.editing = editing
        self.actions = actions
    }
}

/// Macros: a spoken phrase on its own is replaced by saved text. Add, edit and delete, one editor open at a time.
public struct MacrosScreen: View {
    @Bindable private var model: MacrosModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: MacrosModel) {
        self.model = model
    }

    public var body: some View {
        ScreenPage(String(localized: "Macros"),
                   subtitle: String(localized: "Say a phrase on its own and its saved text is pasted instead."),
                   trailing: {
                       Button { open(MacroDraft()) } label: { Label(String(localized: "Add Macro"), systemImage: "plus") }
                           .buttonStyle(PrimaryButtonStyle())
                           .disabled(model.editing != nil)
                   }) {
            if model.macros.isEmpty && model.editing == nil {
                EmptyState(symbol: "text.bubble", title: String(localized: "No macros yet"),
                           message: String(localized: "A macro turns a short phrase, said by itself, into text you use often: an address, a sign-off, a snippet.")) {
                    Button { open(MacroDraft()) } label: { Label(String(localized: "Add Macro"), systemImage: "plus") }
                        .buttonStyle(PrimaryButtonStyle())
                }
            } else {
                Card {
                    if let draft = model.editing, draft.id == nil {
                        MacroEditor(model: model)
                    }
                    ForEach(model.macros) { macro in
                        if model.editing?.id == macro.id {
                            MacroEditor(model: model)
                        } else {
                            MacroRow(macro: macro, isEnabled: model.editing == nil,
                                     edit: { open(MacroDraft(id: macro.id, phrase: macro.phrase, text: macro.text)) },
                                     delete: { model.actions.delete(macro.id) })
                        }
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.editing)
            }
        }
    }

    private func open(_ draft: MacroDraft) {
        model.refusal = nil
        model.editing = draft
    }
}

/// A macro: the phrase in quotes, what it pastes under it, then edit and delete.
private struct MacroRow: View {
    let macro: MacroItem
    let isEnabled: Bool
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "“\(macro.phrase)”")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(macro.text.isEmpty ? String(localized: "Pastes nothing") : macro.text)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .font(.rowDetail)
                .foregroundStyle(Theme.secondaryInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(macro.phrase)
            .accessibilityValue(macro.text.isEmpty ? String(localized: "Pastes nothing") : macro.text)
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel(String(localized: "Edit \(macro.phrase)"))
            Button(action: delete) { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle(destructive: true))
                .accessibilityLabel(String(localized: "Delete \(macro.phrase)"))
        }
        .disabled(!isEnabled)
        .rowPadding()
    }
}

/// The editor, in place of the row it edits or at the top for a new macro: what is said, what is pasted, the
/// inline message, Cancel and Save. Return in the phrase field saves; Escape cancels.
private struct MacroEditor: View {
    @Bindable var model: MacrosModel
    @FocusState private var phraseFocused: Bool

    private var draft: MacroDraft { model.editing ?? MacroDraft() }
    private var problem: MacroProblem? {
        model.refusal ?? model.actions.validate(draft.phrase, draft.text, draft.id)
    }
    private var message: String? {
        MacroProblem.inlineMessage(phrase: draft.phrase, text: draft.text, problem: problem)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field(String(localized: "When I say")) {
                SorelloTextField(String(localized: "sample sign-off"), text: binding(\.phrase),
                                 hasProblem: message != nil, onSubmit: save)
                    .focused($phraseFocused)
                    .accessibilityLabel(String(localized: "When I say"))
            }
            field(String(localized: "Paste")) {
                TextField(text: binding(\.text), prompt: Text("The text to paste").foregroundStyle(Theme.secondaryInk),
                          axis: .vertical) {
                    Text("Paste")
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(3...6)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.pill, in: RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
                    .strokeBorder(Theme.edge, lineWidth: 0.5))
                .accessibilityLabel(String(localized: "Text to paste"))
            }
            HStack(spacing: 8) {
                if let message { InlineMessage(message) }
                Spacer(minLength: 8)
                Button(String(localized: "Cancel")) { model.editing = nil }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save"), action: save)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(problem != nil)
            }
        }
        .padding(Metrics.rowInset)
        .onAppear { phraseFocused = true }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryInk)
                .frame(width: 76, alignment: .trailing)
            content()
        }
    }

    private func binding(_ keyPath: WritableKeyPath<MacroDraft, String>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] },
                set: { value in
                    model.refusal = nil
                    model.editing?[keyPath: keyPath] = value
                })
    }

    private func save() {
        guard problem == nil else { return }
        if let refusal = model.actions.save(draft.id, draft.phrase, draft.text) {
            model.refusal = refusal
        } else {
            model.editing = nil
        }
    }
}
