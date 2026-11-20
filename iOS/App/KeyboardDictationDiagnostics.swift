#if SORELLO_KEYBOARD_DICTATION
import SwiftUI

/// Diagnostics' "Keyboard dictation" section, in experiment builds (ARCHITECTURE.md, "In-keyboard dictation
/// (experiment)"): the "Dictate in the keyboard" switch and the last `keyboard-dictation.json`, read when the screen
/// appears and when Sorello returns to the front. Numbers and fixed names only.
struct KeyboardDictationSection: View {
    let settings: SorelloSettings?
    /// Where the record is read; the App Group's store unless given.
    var store: SharedDictationStore? = SorelloConfiguration.main.flatMap(SharedDictationStore.init(configuration:))
    @State private var enabled = true
    @State private var record: StoreRead<KeyboardDictationRecord> = .absent
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section("Keyboard dictation") {
            Toggle("Dictate in the keyboard", isOn: $enabled)
                .tint(Theme.toggle)
                .disabled(settings == nil)
                .accessibilityIdentifier("diagnostics.keyboardDictation")
            switch record {
            case .value(let record):
                RecordRows(record: record)
            case .absent:
                Text("No dictation yet").foregroundStyle(.secondary)
            case .unreadable, .incompatible:
                Text("Last record unreadable").foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Theme.cardBackground)
        .onAppear(perform: load)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { load() }
        }
        .onChange(of: enabled) { _, value in
            if settings?.keyboardDictationEnabled != value { settings?.keyboardDictationEnabled = value }
        }
    }

    private func load() {
        enabled = settings?.keyboardDictationEnabled ?? true
        record = store?.readKeyboardDictation() ?? .absent
    }
}

private struct RecordRows: View {
    let record: KeyboardDictationRecord

    var body: some View {
        LabeledContent("Start", value: record.warm.map { $0 ? "Warm" : "Cold" } ?? "—")
        if let tappedAt = record.tappedAt {
            LabeledContent("When", value: tappedAt.formatted(date: .abbreviated, time: .standard))
        }
        ForEach(Array(record.steps.enumerated()), id: \.offset) { _, step in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(KeyboardDictationLabels.step(step.step))
                    Spacer()
                    Text(KeyboardDictationLabels.milliseconds(step.milliseconds)).monospacedDigit()
                }
                Text("\(KeyboardDictationLabels.megabytes(step.footprintMB)) · \(KeyboardDictationLabels.megabytes(step.availableMB)) left")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        LabeledContent("Peak (keyboard process)", value: KeyboardDictationLabels.megabytes(record.peakFootprintMB))
        LabeledContent("Least memory left", value: KeyboardDictationLabels.megabytes(record.leastAvailableMB))
        LabeledContent("Audio", value: KeyboardDictationLabels.audio(seconds: record.audioSeconds, rate: record.captureSampleRate))
        LabeledContent("Microphone", value: record.captureInput.map { $0 == .builtIn ? "iPhone" : "Other" } ?? "—")
        LabeledContent("Input level", value: KeyboardDictationLabels.inputLevel(loudest: record.inputLoudestDBFS,
                                                                              typical: record.inputTypicalDBFS))
        LabeledContent("Preparation", value: KeyboardDictationLabels.milliseconds(record.preparationMilliseconds))
        LabeledContent("Stop to text", value: KeyboardDictationLabels.milliseconds(record.stopToTextMilliseconds))
        LabeledContent("Stop to insertion", value: KeyboardDictationLabels.milliseconds(record.stopToInsertionMilliseconds))
        LabeledContent("Text from", value: record.textSource.map { $0 == .stream ? "Stream" : "Batch" } ?? "—")
        LabeledContent("Memory warnings", value: record.memoryWarnings.map(String.init) ?? "—")
        LabeledContent("Outcome", value: KeyboardDictationLabels.outcome(record.outcome))
    }
}

/// The section's words for the record's names and figures; "—" for an unknown one.
enum KeyboardDictationLabels {
    static func step(_ step: KeyboardDictationRecord.Step) -> String {
        switch step {
        case .tapped: return "Tapped"
        case .captureRequested: return "Capture requested"
        case .firstAudio: return "First audio"
        case .modelLoading: return "Model loading"
        case .modelReady: return "Model ready"
        case .firstChunkDecoded: return "First chunk decoded"
        case .stopped: return "Stopped"
        case .transcribed: return "Transcribed"
        case .inserted: return "Inserted"
        case .offered: return "Offered"
        case .dropped: return "Dropped"
        case .ended: return "Ended"
        }
    }

    static func outcome(_ outcome: KeyboardDictationRecord.Outcome?) -> String {
        guard let outcome else { return "Unfinished" }
        switch outcome {
        case .text: return "Text"
        case .noSpeech: return "No speech"
        case .cancelled: return "Cancelled"
        case .abandoned: return "Abandoned"
        case .captureUnavailable: return "Capture unavailable"
        case .startupTimeout: return "No audio in time"
        case .captureLost: return "Capture lost"
        case .modelFailed: return "Model failed"
        case .transcriptionFailed: return "Transcription failed"
        case .keyboardDismissed: return "Keyboard closed"
        case .hostTookOver: return "Sorello took over"
        }
    }

    static func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "—"
    }

    static func megabytes(_ value: Double?) -> String {
        value.map { String(format: "%.0f MB", $0) } ?? "—"
    }

    /// "-38 dB loudest · -55 dB typical", in dBFS.
    static func inputLevel(loudest: Int?, typical: Int?) -> String {
        guard let loudest, let typical else { return "—" }
        return "\(loudest) dB loudest · \(typical) dB typical"
    }

    static func audio(seconds: Double?, rate: Double?) -> String {
        guard let seconds else { return "—" }
        let length = String(format: "%.1f s", seconds)
        return rate.map { length + String(format: " at %.1f kHz", $0 / 1_000) } ?? length
    }
}
#endif
