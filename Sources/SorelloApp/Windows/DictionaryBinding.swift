import DictationCore
import DictionaryKit
import Foundation
import Persistence
import SorelloUI
import TextRules

extension WindowModels {
    /// Dictionary: every change goes through `DictionaryLibrary`, so the store validates and writes it and the
    /// correction coordinator hears of it. A word's id on screen is its identity key.
    func connectDictionary() {
        let model = main.dictionary, library = app.dictionary
        follow {
            let scoped = library.dictionary
            model.words = scoped.dictionary.entries.map { entry in
                DictionaryWord(id: entry.key.text, text: entry.text, strength: Double(entry.strength),
                               apps: scoped.scopes.apps(for: entry.key).sorted().map { id in
                                   AppLimit(id: id, name: scoped.scopes.app(id: id)?.name ?? id)
                               })
            }
            model.ignored = scoped.dictionary.ignore.map { IgnoredWord(id: $0.text, text: $0.text) }
            model.knownApps = scoped.scopes.apps.map { AppLimit(id: $0.id, name: $0.name) }
            model.capacity = DictionaryValidation.capacity
            model.canEdit = library.canEdit
        }
        model.actions = DictionaryActions(
            validate: { text in
                guard library.canEdit else { return .needsModel }
                if case .failure(let error) = DictionaryValidation.validate(
                    text: text, strength: DictionaryValidation.defaultStrength, encoder: library.encoder) {
                    return DictionaryProblem(error)
                }
                return nil
            },
            add: { text, strength, apps in
                do throws(DictionaryChangeError) {
                    try library.save(text: text, strength: Float(strength), apps: Set(apps), replacing: nil)
                    return nil
                } catch {
                    return DictionaryProblem(error)
                }
            },
            setStrength: { id, strength in
                guard let entry = Self.entry(id, in: library) else { return }
                Self.attempt {
                    try library.save(text: entry.text, strength: Float(strength),
                                     apps: library.dictionary.scopes.apps(for: entry.key), replacing: entry.key)
                }
            },
            setApps: { id, apps in
                guard let entry = Self.entry(id, in: library) else { return }
                Self.attempt {
                    try library.save(text: entry.text, strength: entry.strength, apps: Set(apps), replacing: entry.key)
                }
            },
            chooseApp: { [unowned self] id in chooseApp(for: id) },
            delete: { id in Self.attempt { try library.remove(DictionaryKey(id)) } },
            unignore: { id in Self.attempt { try library.unignore(DictionaryKey(id)) } })
    }

    /// The entry whose identity key is `id`.
    static func entry(_ id: String, in library: DictionaryLibrary) -> DictionaryEntry? {
        let key = DictionaryKey(id)
        return library.dictionary.dictionary.entries.first { $0.key == key }
    }

    /// A change made from a row's menu. The screen has no place for its refusal; the row keeps showing what is
    /// stored, which is the truth.
    static func attempt(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            Diagnostics.record("dictionary.changeRefused")
        }
    }

    /// Lets the user choose an app, makes it known, and limits the word to it, or adds it to the add field's apps.
    func chooseApp(for id: String?) {
        let library = app.dictionary, model = main.dictionary, chooser = app.platform.system.chooseApp
        Task {
            guard let chosen = await chooser(),
                  let limit = DictionaryApp(id: chosen.bundleID, name: chosen.name) else { return }
            do throws(DictionaryChangeError) {
                try library.register(limit)
            } catch {
                model.refusal = DictionaryProblem(error)
                return
            }
            guard let id else {
                if !model.draft.apps.contains(limit.id) { model.draft.apps.append(limit.id) }
                return
            }
            guard let entry = Self.entry(id, in: library) else { return }
            let apps = library.dictionary.scopes.apps(for: entry.key).union([limit.id])
            Self.attempt {
                try library.save(text: entry.text, strength: entry.strength, apps: apps, replacing: entry.key)
            }
        }
    }
}

extension WindowModels {
    /// Macros: kept by `MacroStore`, in the order the matcher tries them. A macro's id on screen is its UUID.
    func connectMacros() {
        let model = main.macros, store = app.macros
        follow {
            model.macros = store.macros.map { MacroItem(id: $0.id.uuidString, phrase: $0.command, text: $0.text) }
        }
        model.actions = MacrosActions(
            validate: { phrase, _, id in Self.macroProblem(phrase: phrase, editing: id, in: store.macros) },
            save: { id, phrase, text in
                do throws(MacroStoreError) {
                    if let id {
                        guard let uuid = UUID(uuidString: id), var macro = store.macros.first(where: { $0.id == uuid })
                        else { return .notSaved }
                        macro.command = phrase
                        macro.text = text
                        try store.update(macro)
                    } else {
                        _ = try store.add(command: phrase, text: text)
                    }
                    return nil
                } catch {
                    return MacroProblem(error)
                }
            },
            delete: { id in
                guard let uuid = UUID(uuidString: id) else { return }
                do {
                    try store.delete(id: uuid)
                } catch {
                    Diagnostics.record("macros.deleteRefused")
                }
            })
    }

    /// What the store would refuse, checked as the user types: a command that cannot be said, or another macro's.
    static func macroProblem(phrase: String, editing id: String?, in macros: [VoiceMacro]) -> MacroProblem? {
        let key = VoiceMacro.matchKey(for: phrase)
        if key.isEmpty { return .emptyPhrase }
        if macros.contains(where: { $0.matchKey == key && $0.id.uuidString != id }) { return .duplicatePhrase }
        return nil
    }
}
