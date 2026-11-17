import SwiftUI
import UIKit

/// `NotesLibrary` (HostCore) as SwiftUI state, locked when the app enters the background and as the iPhone locks
/// (ARCHITECTURE.md, "Host app", `NotesLibrary`). The views read the library and draw what `AppScreens` says.
@MainActor
final class NotesModel: ObservableObject {
    let library: NotesLibrary
    private var observers: [NSObjectProtocol] = []

    init(library: NotesLibrary) {
        self.library = library
        library.onChange = { [weak self] in self?.objectWillChange.send() }
        let center = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.protectedDataWillBecomeUnavailableNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.library.lock() }
            })
        }
    }
}

/// The Notes screen (`NotesScreen`): first use, locked, the list with search, or the way back with the recovery code.
/// Record (or Stop) sits under it wherever a note can record or one is in progress.
struct NotesView: View {
    @ObservedObject var model: NotesModel
    @EnvironmentObject private var host: HostSessionController
    @State private var showsSettings = false

    var body: some View {
        let library = model.library
        let screen = library.screen
        Group {
            if library.recoveryCode != nil {
                RecoveryCodeScreen(model: model)
            } else {
                switch screen {
                case .needsPasscode: NotesStep(symbol: "lock.slash", words: NotesWords.passcodeNeeded)
                case .firstUse: NotesStep(symbol: "lock.doc", words: NotesWords.vault)
                case .recoveryOffer: NotesStep(symbol: "key", words: NotesWords.recoveryOffer)
                case .locked: NotesStep(symbol: "lock.fill", words: NotesWords.locked)
                case .unlocked: NotesList(model: model)
                case .secretMissing: SecretMissingScreen(model: model)
                }
            }
        }
        .background(Theme.screenBackground.ignoresSafeArea())
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if screen.showsNotes, library.recoveryCode == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Notes settings")
                        .accessibilityIdentifier("notes.settings")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if library.recoveryCode == nil { actions(screen) }
        }
        .navigationDestination(isPresented: Binding(get: { library.openNoteID != nil }, set: { if !$0 { library.close() } })) {
            NoteView(model: model)
        }
        .navigationDestination(isPresented: $showsSettings) {
            NotesSettingsView(model: model)
        }
        .notesAlert(model)
        .tint(.white)
    }

    /// The screen's own actions, then Record or Stop, pinned under what scrolls.
    @ViewBuilder
    private func actions(_ screen: NotesScreen) -> some View {
        let library = model.library
        let record = NoteRecordButton(offersRecord: screen.offersRecord, note: host.voiceNote?.phase)
        let hasOwn = screen == .firstUse || screen == .recoveryOffer || screen == .locked
        if hasOwn || record != nil {
            VStack(spacing: 12) {
                switch screen {
                case .firstUse:
                    Button {
                        library.makeVault()
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            Label("Set up Notes", systemImage: "faceid")
                            Text("Set up Notes")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("notes.makeVault")
                case .recoveryOffer:
                    Button("Make recovery code") { library.makeRecoveryCode() }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("notes.makeRecoveryCode")
                    Button("Not now") { library.skipRecoveryCode() }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("notes.skipRecoveryCode")
                case .locked:
                    UnlockButton(model: model)
                case .needsPasscode, .unlocked, .secretMissing:
                    EmptyView()
                }
                if let record {
                    RecordPill(button: record) { record == .record ? library.record() : library.stop() }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .actionBarBackground()
        }
    }
}

/// A Notes screen's glyph and words, scrolling over the actions pinned under them. The glyph goes at accessibility
/// sizes, as onboarding's does, so the words keep the width.
private struct NotesStep: View {
    let symbol: String
    let words: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !typeSize.isAccessibilitySize { HeroSymbol(systemName: symbol) }
                Text(words).multilineTextAlignment(.center).foregroundStyle(Theme.secondaryInk)
            }
            .padding(24)
            .padding(.top, 16)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Unlock: the user authenticates, off the main thread (`NotesLibrary.unlock`).
private struct UnlockButton: View {
    @ObservedObject var model: NotesModel

    var body: some View {
        Button {
            model.library.unlock()
        } label: {
            ViewThatFits(in: .horizontal) {
                Label("Unlock", systemImage: "faceid")
                Text("Unlock")
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.library.isUnlocking)
        .accessibilityIdentifier("notes.unlock")
    }
}

/// Record, Stop or Saving: the main pill, with the state's colour on its glyph only.
private struct RecordPill: View {
    let button: NoteRecordButton
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                Label(button.title, systemImage: button.symbol)
                Text(button.title)
            }
        }
        .buttonStyle(PrimaryButtonStyle(accent: button.accent.map(Theme.color)))
        .disabled(!button.isEnabled)
        .accessibilityIdentifier("notes.record")
    }
}

/// The unlocked list: newest first, searched at every keystroke (`NotesLibrary.search`).
private struct NotesList: View {
    @ObservedObject var model: NotesModel

    var body: some View {
        let library = model.library
        List {
            Section {
                SearchRow(query: Binding(get: { library.query }, set: { library.search($0) }))
            }
            .listRowBackground(Theme.cardBackground)
            Section {
                if library.hits.isEmpty {
                    Text(library.query.isEmpty ? "No notes yet. Record one below." : "No notes match.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryInk)
                }
                ForEach(library.hits, id: \.note.id) { hit in
                    Button {
                        library.open(hit.note.id)
                    } label: {
                        NoteRow(hit: hit, isRecording: hit.note.id == library.recordingNoteID, searching: !library.query.isEmpty)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                if let unreadable = NoteRowText.unreadable(library.unreadableCount) {
                    Label(unreadable, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(FootnoteLabelStyle())
                        .foregroundStyle(Theme.ember)
                }
            }
            .listRowBackground(Theme.cardBackground)
        }
        .listStyle(.insetGrouped)
        .themedListBackground()
    }
}

/// The search field, a row of the list, so nothing of it outlives the list when the vault locks.
private struct SearchRow: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.secondaryInk)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityHidden(true)
            TextField("Search notes", text: $query)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .accessibilityIdentifier("notes.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondaryInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .frame(minHeight: 36)
    }
}

private struct NoteRow: View {
    let hit: NoteSearchHit
    let isRecording: Bool
    let searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            words
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if isRecording { StateDot(accent: .coral) }
                date
            }
            .font(.footnote)
            .foregroundStyle(Theme.secondaryInk)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var words: some View {
        if searching {
            let snippet = NoteSnippet(text: hit.note.text, matches: hit.matchedCharacters)
            Text(Self.highlighted(snippet))
        } else if let preview = NoteRowText.preview(hit.note.text) {
            Text(preview)
        } else {
            Text(NoteRowText.empty).foregroundStyle(Theme.secondaryInk)
        }
    }

    private var date: Text {
        let date = hit.note.modified
        switch NoteRowText.dateStyle(date, now: .now, calendar: .current) {
        case .time: return Text(date, format: .dateTime.hour().minute())
        case .dayAndMonth: return Text(date, format: .dateTime.day().month())
        case .fullDate: return Text(date, format: .dateTime.day().month().year())
        }
    }

    /// The snippet in secondary ink, its matches in white and bold.
    static func highlighted(_ snippet: NoteSnippet) -> AttributedString {
        let characters = Array(snippet.text)
        var result = AttributedString()
        var position = 0
        func append(_ range: Range<Int>, matched: Bool) {
            guard !range.isEmpty else { return }
            var part = AttributedString(String(characters[range]))
            part.foregroundColor = matched ? .white : Theme.secondaryInk
            if matched { part.inlinePresentationIntent = .stronglyEmphasized }
            result += part
        }
        for highlight in snippet.highlights {
            append(position ..< highlight.lowerBound, matched: false)
            append(highlight, matched: true)
            position = highlight.upperBound
        }
        append(position ..< characters.count, matched: false)
        return result
    }
}

/// A note (`NoteScreenMode`): recording, its text live and read-only; or editing, an ordinary text field. Locked, the
/// Unlock prompt, and Stop while it records.
struct NoteView: View {
    @ObservedObject var model: NotesModel
    @EnvironmentObject private var host: HostSessionController
    @State private var selection: TextSelection?
    @State private var confirmingDelete = false

    var body: some View {
        let library = model.library
        Group {
            if let id = library.openNoteID {
                let mode = NoteScreenMode(isUnlocked: library.state == .unlocked, noteID: id,
                                          recordingNoteID: library.recordingNoteID, phase: host.voiceNote?.phase)
                content(mode)
                    .safeAreaInset(edge: .bottom, spacing: 0) { actions(mode) }
            }
        }
        .background(Theme.screenBackground.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let id = library.openNoteID,
               NoteScreenMode(isUnlocked: library.state == .unlocked, noteID: id, recordingNoteID: library.recordingNoteID,
                              phase: host.voiceNote?.phase).isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        confirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete note")
                    .accessibilityIdentifier("note.delete")
                    .confirmationDialog("Delete this note?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) { library.deleteOpenNote() }
                    } message: {
                        Text("It can’t be recovered.")
                    }
                }
            }
        }
        .notesAlert(model)
        .tint(.white)
    }

    /// The note's date, unlocked only.
    private var title: Text {
        guard model.library.state == .unlocked, let note = model.library.openNote else { return Text(verbatim: "") }
        return Text(note.created, format: .dateTime.day().month().year())
    }

    @ViewBuilder
    private func content(_ mode: NoteScreenMode) -> some View {
        let library = model.library
        if !mode.showsText {
            NotesStep(symbol: "lock.fill", words: NotesWords.locked)
        } else if mode.isLive {
            LiveNoteText(live: library.liveText, mode: mode, startedAt: host.voiceNote?.startedAt)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let ending = library.openNoteEnding?.message {
                    Label(ending, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.ember)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }
                TextEditor(text: Binding(get: { library.draft ?? "" }, set: { library.edit($0) }), selection: $selection)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 15)
                    .accessibilityIdentifier("note.text")
            }
        }
    }

    @ViewBuilder
    private func actions(_ mode: NoteScreenMode) -> some View {
        let library = model.library
        VStack(spacing: 12) {
            if !mode.showsText { UnlockButton(model: model) }
            if mode.offersStop {
                RecordPill(button: .stop) { library.stop() }
            } else if case .editing(let canResume) = mode {
                Button {
                    library.resume(at: NoteCursor.place(selection: cursor, in: library.draft ?? ""))
                } label: {
                    ViewThatFits(in: .horizontal) {
                        Label("Resume", systemImage: "mic.fill")
                        Text("Resume")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canResume)
                .accessibilityIdentifier("note.resume")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .actionBarBackground()
    }

    /// The text field's cursor, or the end of its selection; nil before it has one.
    private var cursor: Range<String.Index>? {
        switch selection?.indices {
        case .selection(let range)?: return range
        case .multiSelection(let ranges)?: return ranges.ranges.last
        case nil: return nil
        @unknown default: return nil
        }
    }
}

/// The recording note's text: the vault's, with the provisional tail dimmed at the run's place.
private struct LiveNoteText: View {
    let live: NoteLiveText?
    let mode: NoteScreenMode
    let startedAt: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                Color.clear.frame(height: 1).id(Self.end)
            }
            // While the run is at the note's end, the view follows the words as they arrive.
            .onChange(of: live) {
                guard live?.after.isEmpty == true else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
        }
    }

    private static let end = "end"

    private var content: some View {
            VStack(alignment: .leading, spacing: 12) {
                if let status = mode.status {
                    HStack(spacing: 8) {
                        StateDot(accent: mode.accent)
                        Text(status)
                        if mode == .recording, let startedAt {
                            Text(timerInterval: startedAt ... Date.distantFuture, countsDown: false).monospacedDigit()
                        }
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.secondaryInk)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("note.status")
                }
                if let live {
                    Text(Self.text(live))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("note.liveText")
                }
            }
            .padding(20)
    }

    static func text(_ live: NoteLiveText) -> AttributedString {
        var tail = AttributedString(live.provisional)
        tail.foregroundColor = Theme.secondaryInk
        return AttributedString(live.before) + tail + AttributedString(live.after)
    }
}

/// A recovery code just made, shown once with what it is for.
private struct RecoveryCodeScreen: View {
    @ObservedObject var model: NotesModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !typeSize.isAccessibilitySize { HeroSymbol(systemName: "key") }
                if let code = model.library.recoveryCode {
                    Text(verbatim: code.replacingOccurrences(of: "-", with: " "))
                        .font(.title3.monospaced().weight(.semibold))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .islandSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("Recovery code")
                        .accessibilityValue(code.map { String($0) }.joined(separator: " "))
                        .accessibilityIdentifier("notes.recoveryCode")
                }
                Text(NotesWords.recoveryWarning).multilineTextAlignment(.center).foregroundStyle(Theme.secondaryInk)
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Done") { model.library.doneWithRecoveryCode() }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("notes.recoveryCodeDone")
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .actionBarBackground()
        }
        .background(Theme.screenBackground.ignoresSafeArea())
    }
}

/// Notes on this iPhone without the key: the recovery code puts it back, or everything is erased.
private struct SecretMissingScreen: View {
    @ObservedObject var model: NotesModel
    @State private var code = ""
    @State private var confirmingErase = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !typeSize.isAccessibilitySize { HeroSymbol(systemName: "key") }
                Text(NotesWords.secretMissing).multilineTextAlignment(.center).foregroundStyle(Theme.secondaryInk)
                TextField("Recovery code", text: $code)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(14)
                    .islandSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("notes.recoveryCodeField")
                Button("Open notes") {
                    model.library.restore(recoveryCode: code)
                    if model.library.state == .unlocked { code = "" }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("notes.restore")
                Button("Erase all notes…", role: .destructive) { confirmingErase = true }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.coral))
            }
            .padding(24)
        }
        .eraseConfirmation(isPresented: $confirmingErase) { model.library.eraseAll() }
    }
}

/// Notes settings: the recovery code, Lock now, Erase all notes. It closes once the vault is no longer unlocked.
struct NotesSettingsView: View {
    @ObservedObject var model: NotesModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReplace = false
    @State private var confirmingErase = false

    var body: some View {
        let library = model.library
        Group {
            if library.recoveryCode != nil {
                RecoveryCodeScreen(model: model)
            } else {
                List {
                    Section {
                        Button {
                            if library.hasRecoveryCode { confirmingReplace = true } else { library.makeRecoveryCode() }
                        } label: {
                            Label(library.hasRecoveryCode ? "Replace recovery code" : "Make recovery code", systemImage: "key")
                        }
                        .accessibilityIdentifier("notes.settings.recoveryCode")
                    } footer: {
                        Text(NotesWords.recoverySetting)
                    }
                    .listRowBackground(Theme.cardBackground)
                    Section {
                        Button {
                            library.lock()
                        } label: {
                            Label("Lock now", systemImage: "lock")
                        }
                        .accessibilityIdentifier("notes.settings.lock")
                    }
                    .listRowBackground(Theme.cardBackground)
                    Section {
                        Button(role: .destructive) {
                            confirmingErase = true
                        } label: {
                            Label("Erase all notes…", systemImage: "trash")
                        }
                        .foregroundStyle(Theme.coral)
                        .accessibilityIdentifier("notes.settings.erase")
                    }
                    .listRowBackground(Theme.cardBackground)
                }
                .listStyle(.insetGrouped)
                .themedListBackground()
                .tint(.white)
            }
        }
        .navigationTitle("Notes settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Replace the recovery code?", isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button("Replace") { library.makeRecoveryCode() }
        } message: {
            Text("The code you have now stops working.")
        }
        .eraseConfirmation(isPresented: $confirmingErase) { library.eraseAll() }
        .onChange(of: library.state, initial: true) {
            if library.state != .unlocked { dismiss() }
        }
        .notesAlert(model)
    }
}

private extension View {
    func eraseConfirmation(isPresented: Binding<Bool>, erase: @escaping () -> Void) -> some View {
        confirmationDialog("Erase all notes?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Erase all notes", role: .destructive, action: erase)
        } message: {
            Text("Every note on this iPhone and its recovery code are deleted. This can’t be undone.")
        }
    }

    /// The library's last refusal, as an alert.
    func notesAlert(_ model: NotesModel) -> some View {
        alert("Notes", isPresented: Binding(get: { model.library.message != nil }, set: { if !$0 { model.library.dismissMessage() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.library.message ?? "")
        }
    }
}
