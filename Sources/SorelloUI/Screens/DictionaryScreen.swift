import SwiftUI

/// What the Dictionary screen asks of the app layer, which edits the dictionary through its editor.
public struct DictionaryActions {
    /// Checks what is typed in the add field, as the dictionary would; nil when it can be added.
    public var validate: (String) -> DictionaryProblem?
    /// Adds a word limited to the given apps (none: everywhere). Returns why it was refused, or nil.
    public var add: (_ text: String, _ strength: Double, _ apps: [String]) -> DictionaryProblem?
    /// Sets a word's strength to one of the presets.
    public var setStrength: (_ wordID: String, _ strength: Double) -> Void
    /// Sets the apps a word is limited to; empty makes it apply everywhere.
    public var setApps: (_ wordID: String, _ apps: [String]) -> Void
    /// Lets the user choose another app, from those running or in Applications, and limits the word to it. With a
    /// nil word, the app is added to the add field's choice.
    public var chooseApp: (_ wordID: String?) -> Void
    /// Removes a word and its app limits.
    public var delete: (_ wordID: String) -> Void
    /// Takes a word off the ignore list, so it can be suggested again.
    public var unignore: (_ ignoredID: String) -> Void

    /// Actions that accept everything and change nothing unless given.
    public init(validate: @escaping (String) -> DictionaryProblem? = { _ in nil },
                add: @escaping (String, Double, [String]) -> DictionaryProblem? = { _, _, _ in nil },
                setStrength: @escaping (String, Double) -> Void = { _, _ in },
                setApps: @escaping (String, [String]) -> Void = { _, _ in },
                chooseApp: @escaping (String?) -> Void = { _ in },
                delete: @escaping (String) -> Void = { _ in },
                unignore: @escaping (String) -> Void = { _ in }) {
        self.validate = validate
        self.add = add
        self.setStrength = setStrength
        self.setApps = setApps
        self.chooseApp = chooseApp
        self.delete = delete
        self.unignore = unignore
    }
}

/// The word being typed into the add field.
public struct DictionaryDraft: Equatable, Sendable {
    /// What is typed.
    public var text: String
    /// The preset chosen for it.
    public var strength: Double
    /// Bundle identifiers; empty means everywhere.
    public var apps: [String]

    /// An empty draft at the default strength, everywhere.
    public init(text: String = "", strength: Double = StrengthPresets.defaultValue, apps: [String] = []) {
        self.text = text
        self.strength = strength
        self.apps = apps
    }
}

/// The Dictionary screen's values.
@Observable
public final class DictionaryModel {
    /// The entries, in the dictionary's order.
    public var words: [DictionaryWord]
    /// Words that are never suggested.
    public var ignored: [IgnoredWord]
    /// Apps words can be limited to: every app already used for a limit, and any the user has added.
    public var knownApps: [AppLimit]
    /// The most entries the dictionary holds.
    public var capacity: Int
    /// False without the speech model's vocabulary: nothing can be checked, so nothing can be changed.
    public var canEdit: Bool
    /// The add field's contents. Changing any part of it clears `refusal`.
    public var draft: DictionaryDraft {
        didSet { if draft != oldValue { refusal = nil } }
    }
    /// Why the last add was refused, until the draft changes.
    public var refusal: DictionaryProblem?
    /// What the screen asks of the app layer.
    public var actions: DictionaryActions

    /// The Dictionary screen's values.
    public init(words: [DictionaryWord], ignored: [IgnoredWord], knownApps: [AppLimit], capacity: Int = 1000,
                canEdit: Bool = true, draft: DictionaryDraft = DictionaryDraft(), actions: DictionaryActions = DictionaryActions()) {
        self.words = words
        self.ignored = ignored
        self.knownApps = knownApps
        self.capacity = capacity
        self.canEdit = canEdit
        self.draft = draft
        self.actions = actions
    }

    /// The problem the add field shows: the dictionary as a whole first, then what is typed.
    var draftProblem: DictionaryProblem? {
        if !canEdit { return .needsModel }
        if words.count >= capacity { return .full(capacity: capacity) }
        return refusal ?? actions.validate(draft.text)
    }

    func appName(_ id: String) -> String {
        knownApps.first { $0.id == id }?.name ?? id
    }
}

/// Dictionary: names and terms that bias the recognizer, each with a strength and optional app limits; the count
/// against the limit; and the words that are never suggested.
public struct DictionaryScreen: View {
    @Bindable private var model: DictionaryModel

    /// The Dictionary screen drawn from `model`.
    public init(model: DictionaryModel) {
        self.model = model
    }

    public var body: some View {
        ScreenPage(String(localized: "Dictionary"),
                   subtitle: String(localized: "Names and terms the recognizer should expect, each with a strength."),
                   trailing: {
                       Text(DictionaryCount.label(count: model.words.count, capacity: model.capacity))
                           .font(.system(size: 12).monospacedDigit())
                           .foregroundStyle(Theme.secondaryInk)
                   }) {
            CardGroup(String(localized: "Add a word")) {
                AddWordCard(model: model)
            }
            CardGroup(String(localized: "Words")) {
                if model.words.isEmpty {
                    EmptyState(symbol: "character.book.closed", title: String(localized: "No words yet"),
                               message: String(localized: "Add names and terms that get misheard. A higher strength pulls harder toward the spelling."))
                } else {
                    Card {
                        ForEach(model.words) { word in
                            WordRow(word: word, model: model)
                        }
                    }
                }
            } footer: {
                if !model.words.isEmpty {
                    Text("A word limited to apps is used only when you dictate into one of them.")
                }
            }
            CardGroup(String(localized: "Never suggested")) {
                if model.ignored.isEmpty {
                    Text("Words you ask not to have suggested appear here.")
                        .font(.rowDetail)
                        .foregroundStyle(Theme.secondaryInk)
                        .rowPadding()
                        .cardSurface()
                } else {
                    FlowLayout {
                        ForEach(model.ignored) { word in
                            Chip(word.text, onRemove: model.canEdit ? { model.actions.unignore(word.id) } : nil)
                        }
                    }
                    .padding(Metrics.rowInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
                }
            } footer: {
                if !model.ignored.isEmpty {
                    Text("Remove a word to let it be suggested again.")
                }
            }
        }
    }
}

/// The add field, the strength presets, the apps the word is limited to, and the inline message.
private struct AddWordCard: View {
    @Bindable var model: DictionaryModel

    private var problem: DictionaryProblem? { model.draftProblem }
    private var message: String? { DictionaryProblem.inlineMessage(draft: model.draft.text, problem: problem) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SorelloTextField(String(localized: "Word or phrase"), text: $model.draft.text,
                                 hasProblem: message != nil, onSubmit: add)
                    .disabled(!model.canEdit)
                    .accessibilityLabel(String(localized: "Word or phrase"))
                Button(String(localized: "Add"), action: add)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(problem != nil || model.draft.text.isEmpty)
            }
            HStack(spacing: 10) {
                Text("Strength")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryInk)
                PresetPicker(String(localized: "Strength"), options: StrengthPresets.values,
                             selection: $model.draft.strength, label: StrengthPresets.label,
                             spokenLabel: StrengthPresets.spokenLabel)
                Spacer(minLength: 0)
            }
            .disabled(!model.canEdit)
            HStack(spacing: 10) {
                Text("Use in")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryInk)
                AppLimitMenu(selected: model.draft.apps, knownApps: model.knownApps,
                             set: { model.draft.apps = $0 }, chooseOther: { model.actions.chooseApp(nil) })
                Spacer(minLength: 0)
            }
            .disabled(!model.canEdit)
            if let message {
                InlineMessage(message)
            }
        }
        .padding(Metrics.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func add() {
        guard problem == nil, !model.draft.text.isEmpty else { return }
        if let refusal = model.actions.add(model.draft.text, model.draft.strength, model.draft.apps) {
            model.refusal = refusal
        } else {
            model.draft = DictionaryDraft(strength: model.draft.strength)
        }
    }
}

/// One word: its text and app limits, its strength as a menu of presets, its limits menu, and delete.
private struct WordRow: View {
    let word: DictionaryWord
    let model: DictionaryModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(word.text)
                    .font(.rowTitle)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !word.apps.isEmpty {
                    FlowLayout(spacing: 4, lineSpacing: 4) {
                        ForEach(word.apps) { app in Chip(app.name) }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "Only in \(word.apps.map(\.name).formatted(.list(type: .and)))"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StrengthMenu(strength: word.strength) { model.actions.setStrength(word.id, $0) }
            AppLimitMenu(selected: word.apps.map(\.id), knownApps: model.knownApps, compact: true,
                         set: { model.actions.setApps(word.id, $0) }, chooseOther: { model.actions.chooseApp(word.id) })
            Button { model.actions.delete(word.id) } label: { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle(destructive: true))
                .accessibilityLabel(String(localized: "Delete \(word.text)"))
        }
        .disabled(!model.canEdit)
        .padding(.horizontal, Metrics.rowInset)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: Metrics.rowMinHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(word.text)
    }
}

/// A word's strength as a pop-up of the presets.
private struct StrengthMenu: View {
    let strength: Double
    let set: (Double) -> Void

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { StrengthPresets.nearest(to: strength) }, set: { set($0) })) {
                ForEach(StrengthPresets.values, id: \.self) { value in
                    Text(StrengthPresets.label(value)).tag(value)
                }
            } label: { EmptyView() }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            MenuLabel(title: StrengthPresets.label(strength))
                .monospacedDigit()
        }
        .menuStyle(.button)
        .buttonStyle(MenuLabelStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "Strength"))
        .accessibilityValue(StrengthPresets.spokenLabel(strength))
    }
}

/// The apps a word is limited to: "Everywhere", or a check beside each chosen app, and a way to choose another.
private struct AppLimitMenu: View {
    let selected: [String]
    let knownApps: [AppLimit]
    var compact = false
    let set: ([String]) -> Void
    let chooseOther: () -> Void

    var body: some View {
        Group {
            if compact {
                menu {
                    Image(systemName: selected.isEmpty ? "globe" : "app.badge.checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(IconMenuStyle())
            } else {
                menu { MenuLabel(title: title) }
                    .buttonStyle(MenuLabelStyle())
            }
        }
        .accessibilityLabel(String(localized: "Apps"))
        .accessibilityValue(title)
    }

    private func menu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            Toggle(String(localized: "Everywhere"), isOn: Binding(get: { selected.isEmpty }, set: { if $0 { set([]) } }))
            if !knownApps.isEmpty {
                Section(String(localized: "Only in")) {
                    ForEach(knownApps) { app in
                        Toggle(app.name, isOn: Binding(
                            get: { selected.contains(app.id) },
                            set: { on in set(on ? selected + [app.id] : selected.filter { $0 != app.id }) }))
                    }
                }
            }
            Divider()
            Button(String(localized: "Other App…"), action: chooseOther)
        } label: {
            label()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var title: String {
        if selected.isEmpty { return String(localized: "Everywhere") }
        let names = selected.map { id in knownApps.first { $0.id == id }?.name ?? id }
        return names.formatted(.list(type: .and))
    }
}

/// A round glyph-only face for a menu, lit under the pointer.
private struct IconMenuStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconMenuBody(configuration: configuration)
    }
}

private struct IconMenuBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(hovering ? Theme.ink : Theme.secondaryInk)
            .background(Circle().fill(hovering ? Theme.hover : .clear))
            .focusRing(Circle(), isFocused: isFocused)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onHover { hovering = $0 }
    }
}
