import DictationCore
import Foundation
import Observation
import TextRules

/// The user's voice macros, kept in `macros.json` (ARCHITECTURE.md, section 7). Observable, in the order the user
/// gave them, which is also the order the matcher tries them.
///
/// Every change is written before it is published. A change that cannot be saved is undone and reported, so the
/// list on screen is always what is on disk. A file that cannot be read is moved aside and replaced with an empty
/// one; nothing the user made is deleted. If it cannot even be moved, the list starts empty and no change is saved
/// over the file until it has been moved.
@MainActor
@Observable
public final class MacroStore {
    /// The macros, in order.
    public private(set) var macros: [VoiceMacro]

    @ObservationIgnored private let fileURL: URL
    /// A file that could not be read and has not yet been moved aside. Nothing is written over it until it has been
    /// moved, or is confirmed gone.
    @ObservationIgnored private var unreadableFilePending = false

    private struct File: Codable {
        static let currentVersion = 1
        var version: Int
        var macros: [VoiceMacro]
    }

    /// Loads the macros from `fileURL`; a missing file is an empty list.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        switch StoredFile.readVersioned(File.self, from: fileURL, version: File.currentVersion) {
        case .value(let file):
            macros = file.macros
        case .missing:
            macros = []
        case .unreadable:
            macros = []
            Diagnostics.record("macros.unreadable")
            if StoredFile.moveAside(fileURL) {
                try? Self.write([], to: fileURL)
            } else {
                unreadableFilePending = true
            }
        case .inaccessible:
            // Possibly a good file behind a permission problem: leave it where it is, and protect it from a save.
            macros = []
            Diagnostics.record("macros.inaccessible")
            unreadableFilePending = true
        }
    }

    /// Adds a macro at the end of the list. The command is trimmed; the text is kept exactly as given.
    @discardableResult
    public func add(command: String, text: String) throws(MacroStoreError) -> VoiceMacro {
        let macro = VoiceMacro(command: command.trimmingCharacters(in: .whitespacesAndNewlines), text: text)
        try validate(macro)
        try save(macros + [macro])
        return macro
    }

    /// Replaces the macro with `macro.id` by `macro`, in the same place. The command is trimmed.
    public func update(_ macro: VoiceMacro) throws(MacroStoreError) {
        guard let index = macros.firstIndex(where: { $0.id == macro.id }) else { throw .notFound }
        var edited = macro
        edited.command = macro.command.trimmingCharacters(in: .whitespacesAndNewlines)
        try validate(edited)
        var updated = macros
        updated[index] = edited
        try save(updated)
    }

    /// Removes the macro with `id`. Removing one that is not there does nothing.
    public func delete(id: VoiceMacro.ID) throws(MacroStoreError) {
        guard macros.contains(where: { $0.id == id }) else { return }
        try save(macros.filter { $0.id != id })
    }

    /// Moves the macros at `offsets` so they sit before the macro now at `destination`, keeping their order, as a
    /// list's drag and drop reports it. Offsets outside the list are ignored.
    public func move(fromOffsets offsets: IndexSet, toOffset destination: Int) throws(MacroStoreError) {
        let moving = offsets.filter { macros.indices.contains($0) }
        guard !moving.isEmpty else { return }
        let target = min(max(destination, 0), macros.count)
        var reordered = macros.enumerated().filter { !moving.contains($0.offset) }.map(\.element)
        let insertAt = target - moving.filter { $0 < target }.count
        reordered.insert(contentsOf: moving.map { macros[$0] }, at: insertAt)
        guard reordered != macros else { return }
        try save(reordered)
    }

    /// The macros saved in `fileURL`, read without changing anything: no directory is made, and a file that cannot
    /// be read is neither moved nor replaced. An empty list when there is no file; nil when there is one that cannot
    /// be opened or read as macros. For the `sorello` command, which only reads the app's files (ARCHITECTURE.md,
    /// section 10, "The command").
    public nonisolated static func readWithoutChanging(_ fileURL: URL) -> [VoiceMacro]? {
        switch StoredFile.readVersioned(File.self, from: fileURL, version: File.currentVersion) {
        case .value(let file): file.macros
        case .missing: []
        case .unreadable, .inaccessible: nil
        }
    }

    // MARK: - Private

    /// A command must be sayable and must not be another macro's: the matcher compares commands by
    /// `VoiceMacro.matchKey`, so two with the same key would be one command.
    private func validate(_ macro: VoiceMacro) throws(MacroStoreError) {
        let key = macro.matchKey
        guard !key.isEmpty else { throw .emptyCommand }
        if macros.contains(where: { $0.id != macro.id && $0.matchKey == key }) { throw .duplicateCommand }
    }

    private func save(_ updated: [VoiceMacro]) throws(MacroStoreError) {
        if unreadableFilePending {
            // The file may have become readable or gone since; only a file still there is moved, and nothing is
            // written over one that could not be.
            guard StoredFile.isConfirmedMissing(fileURL) || StoredFile.moveAside(fileURL) else {
                Diagnostics.record("macros.saveFailed")
                throw .saveFailed
            }
            unreadableFilePending = false
        }
        do {
            try Self.write(updated, to: fileURL)
        } catch {
            Diagnostics.record("macros.saveFailed")
            throw .saveFailed
        }
        macros = updated
    }

    private static func write(_ macros: [VoiceMacro], to url: URL) throws {
        try StoredFile.ensureDirectory(url.deletingLastPathComponent())
        try StoredFile.writeVersioned(File(version: File.currentVersion, macros: macros), to: url)
    }
}

/// Why a macro change was refused.
public enum MacroStoreError: Error, Sendable, Equatable {
    /// The command is empty, or only punctuation and spaces, so it could never be said.
    case emptyCommand
    /// Another macro already has this command, ignoring case and punctuation.
    case duplicateCommand
    /// No macro has that id.
    case notFound
    /// The file could not be written. Nothing changed.
    case saveFailed
}
