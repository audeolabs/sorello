import AVFoundation
import DictationCore
import Foundation
import Persistence
import SorelloUI

extension WindowModels {
    /// Run Log: the last 20 dictations, to play, transcribe again, copy or delete (ARCHITECTURE.md, section 7). Clear
    /// also makes the session forget the last dictation and the engine let go of audio kept for a suggestion.
    func connectRunLog() {
        let model = main.runLog, app = self.app
        follow {
            model.items = app.history.entries.map(RunLogItem.init)
            model.playingID = app.live.playingID
            model.retryingIDs = app.live.retryingIDs
            model.isEnabled = app.settings.keepRunLog
        }
        model.actions = RunLogActions(
            play: { [unowned self] id in play(id) },
            stop: { [unowned self] in player.stop() },
            retry: { [unowned self] id in retry(id) },
            copy: { id in
                guard let entry = app.history.entries.first(where: { $0.id.uuidString == id }) else { return }
                let words = entry.text.isEmpty ? entry.heard : entry.text
                if !words.isEmpty { app.platform.system.copy(words) }
            },
            delete: { [unowned self] id in
                guard let uuid = UUID(uuidString: id) else { return }
                if app.live.playingID == id { player.stop() }
                Task { await app.history.delete(id: uuid) }
            },
            clearAll: { [unowned self] in clearRunLog() },
            turnOn: { app.settings.keepRunLog = true })
    }

    func play(_ id: String) {
        guard let uuid = UUID(uuidString: id), let url = app.history.audioURL(for: uuid) else { return }
        app.live.playingID = player.play(url) ? id : nil
    }

    /// Transcribes the entry's audio again with today's dictionary and text rules and replaces its words. It never
    /// pastes or presses a key. A retry that hears nothing, fails, or would change what kind of dictation the entry
    /// was (`retryKeepsKind`) leaves the entry as it was.
    func retry(_ id: String) {
        let app = self.app
        guard let uuid = UUID(uuidString: id), !app.live.retryingIDs.contains(id) else { return }
        app.live.retryingIDs.insert(id)
        Task {
            defer { app.live.retryingIDs.remove(id) }
            guard let samples = await app.history.samples(for: uuid) else { return }
            let transcript: String
            do {
                transcript = try await app.speech.transcribe(samples, appBundleID: nil)
            } catch {
                Diagnostics.record("runLog.retryFailed")
                return
            }
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let entry = app.history.entries.first(where: { $0.id == uuid }) else { return }
            let processed = TextRulesSnapshot(settings: app.settings, macros: app.macros.macros)
                .process(transcript, style: .plain, context: nil)
            guard Self.retryKeepsKind(entry, text: processed.text) else { return }
            await app.history.replace(id: uuid, heard: transcript, text: processed.text,
                                      outcome: Self.outcomeAfterRetry(entry.outcome))
        }
    }

    /// Whether a retry's `text` may replace the entry's. A row reads an entry's words together with how it ended: an
    /// entry with words pasted them, and one that was heard but has no words was only a command. A retry does neither,
    /// so it never turns one kind into the other. An entry whose transcription had failed has no kind to keep.
    static func retryKeepsKind(_ entry: HistoryEntry, text: String) -> Bool {
        entry.heard.isEmpty || entry.text.isEmpty == text.isEmpty
    }

    /// A retry never pastes, so an entry whose transcription had failed now has words that were never pasted.
    static func outcomeAfterRetry(_ outcome: DictationOutcome) -> DictationOutcome {
        outcome == .transcriptionFailed ? .insertionFailed : outcome
    }

    /// Clear: every entry and its audio, the remembered text for Paste Again, and any audio kept for a suggestion
    /// (ARCHITECTURE.md, section 9, invariant 3). If some files stayed behind, the user is told.
    func clearRunLog() {
        let app = self.app
        player.stop()
        app.corrections.runLogCleared()
        app.runtime.forgetLast()
        Task {
            guard await !app.history.clear() else { return }
            app.navigation.alert(
                String(localized: "Some Run Log files couldn’t be deleted", comment: "Alert title"),
                String(localized: "They are still listed. Try Clear again; if it keeps failing, check the permissions of the app’s folder in Application Support.",
                       comment: "Alert message after a Run Log clear that left files behind"))
        }
    }
}

extension RunLogItem {
    /// A Run Log entry as its row shows it.
    init(_ entry: HistoryEntry) {
        let outcome: RunLogOutcome = switch entry.outcome {
        case .inserted: .inserted
        case .leftOnClipboard: .leftOnClipboard
        case .insertionFailed: .insertionFailed
        case .transcriptionFailed: .transcriptionFailed
        }
        self.init(id: entry.id.uuidString, date: entry.date, heard: entry.heard, text: entry.text, outcome: outcome,
                  duration: entry.duration)
    }
}

/// Plays one Run Log recording at a time.
@MainActor
final class RunLogPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    /// The recording stopped or finished.
    var onStop: () -> Void = {}

    /// Plays `url`, stopping whatever played before; false if it cannot be played.
    func play(_ url: URL) -> Bool {
        player?.stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            self.player = nil
            return false
        }
        player.delegate = self
        self.player = player
        return player.play()
    }

    func stop() {
        player?.stop()
        player = nil
        onStop()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(finished)
        Task { @MainActor in
            guard let player = self.player, ObjectIdentifier(player) == finished else { return }
            self.player = nil
            self.onStop()
        }
    }
}
