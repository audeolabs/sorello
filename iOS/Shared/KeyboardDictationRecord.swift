#if SORELLO_KEYBOARD_DICTATION
import Foundation

/// How an in-keyboard dictation failed (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Phases).
enum KeyboardDictationFailure: String, Codable, Sendable, CaseIterable {
    /// The web view could not capture; nothing was heard, so the tap goes on as a host tap.
    case captureUnavailable
    /// No audio within `KeyboardDictationTiming.startupTimeout` of the tap; as above.
    case startupTimeout
    /// After audio arrived, capture stopped by itself, a chunk was malformed or late, or the queue overflowed.
    case captureLost
    case modelFailed
    case transcriptionFailed
    case keyboardDismissed
    /// The host took the microphone (`KeyboardDictationRoute.hostOwnsMicrophone`).
    case hostTookOver

    /// The host's words this failure shows, nil for one that shows nothing or goes to the host instead.
    var shownError: HostErrorCode? {
        switch self {
        case .captureLost: return .interrupted
        case .modelFailed: return .modelFailed
        case .transcriptionFailed: return .transcriptionFailed
        case .captureUnavailable, .startupTimeout, .keyboardDismissed, .hostTookOver: return nil
        }
    }

    /// Nothing was heard: the tap goes on as a host tap would, if the keyboard is still there for it.
    var fallsBackToHost: Bool { self == .captureUnavailable || self == .startupTimeout }
}

/// What the process's memory was at one moment, in MB: the footprint jetsam counts (`phys_footprint`), the
/// process's lifetime high-water mark of it (`ledger_phys_footprint_peak`) and what iOS still allows
/// (`os_proc_available_memory`). Any may be unknown.
struct KeyboardMemorySample: Equatable, Sendable {
    var footprintMB: Double?
    var peakMB: Double?
    var availableMB: Double?
}

/// `keyboard-dictation.json`: the last in-keyboard dictation's steps and figures (ARCHITECTURE.md, "In-keyboard
/// dictation (experiment)", Record). Only numbers and fixed names: never audio, text, or anything about the field or
/// the app. Every field but the schema may be missing, and then reads as unknown.
struct KeyboardDictationRecord: Codable, Equatable, Sendable {
    enum Step: String, Codable, Sendable, CaseIterable {
        case tapped, captureRequested, firstAudio, modelLoading, modelReady, firstChunkDecoded, stopped, transcribed,
             inserted, offered, dropped, ended
    }

    /// How it ended, written when the text is ready (before it is inserted, offered or dropped); none while it runs. A
    /// record without one is unfinished.
    enum Outcome: String, Codable, Sendable, CaseIterable {
        case text, noSpeech, cancelled, abandoned
        case captureUnavailable, startupTimeout, captureLost, modelFailed, transcriptionFailed, keyboardDismissed,
             hostTookOver

        init(_ failure: KeyboardDictationFailure) {
            self = Outcome(rawValue: failure.rawValue)!
        }

        var failure: KeyboardDictationFailure? { KeyboardDictationFailure(rawValue: rawValue) }
    }

    /// Where the text came from.
    enum TextSource: String, Codable, Sendable { case stream, batch }

    /// The microphone the capture page believed it recorded from: whether the track's label named the iPhone.
    enum CaptureInput: String, Codable, Sendable { case builtIn, other }

    struct StepRecord: Codable, Equatable, Sendable {
        var step: Step
        /// Since the tap, on the monotonic clock.
        var milliseconds: Double?
        var footprintMB: Double?
        var availableMB: Double?
    }

    var schema: Int = DictationProtocol.schema
    /// The attempt's in-memory id: a later step is added only while the record still has it.
    var attemptID: UUID?
    /// The writer's random id, made once per keyboard process and kept in memory, naming nothing: a later process can
    /// tell a record it did not write.
    var processID: UUID?
    var tappedAt: Date?
    var iosVersion: String?
    /// The engine was already loaded at the tap.
    var warm: Bool?
    var steps: [StepRecord] = []
    var peakFootprintMB: Double?
    var leastAvailableMB: Double?
    var audioSeconds: Double?
    var captureSampleRate: Double?
    var captureInput: CaptureInput?
    /// The loudest and the median captured chunk's RMS over the sealed recording, in whole dBFS.
    var inputLoudestDBFS: Int?
    var inputTypicalDBFS: Int?
    var preparationMilliseconds: Double?
    var stopToTextMilliseconds: Double?
    var stopToInsertionMilliseconds: Double?
    var textSource: TextSource?
    var memoryWarnings: Int?
    var outcome: Outcome?

    init(attemptID: UUID, processID: UUID, tappedAt: Date, iosVersion: String, warm: Bool) {
        self.attemptID = attemptID
        self.processID = processID
        self.tappedAt = tappedAt
        self.iosVersion = iosVersion
        self.warm = warm
        memoryWarnings = 0
    }

    private enum CodingKeys: String, CodingKey {
        case schema, attemptID, processID, tappedAt, iosVersion, warm, steps, peakFootprintMB, leastAvailableMB, audioSeconds,
             captureSampleRate, captureInput, preparationMilliseconds, stopToTextMilliseconds, stopToInsertionMilliseconds,
             textSource, memoryWarnings, outcome, inputLoudestDBFS, inputTypicalDBFS
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(Int.self, forKey: .schema)
        attemptID = try values.decodeIfPresent(UUID.self, forKey: .attemptID)
        processID = try values.decodeIfPresent(UUID.self, forKey: .processID)
        tappedAt = try values.decodeIfPresent(Date.self, forKey: .tappedAt)
        iosVersion = try values.decodeIfPresent(String.self, forKey: .iosVersion)
        warm = try values.decodeIfPresent(Bool.self, forKey: .warm)
        steps = try values.decodeIfPresent([StepRecord].self, forKey: .steps) ?? []
        peakFootprintMB = try values.decodeIfPresent(Double.self, forKey: .peakFootprintMB)
        leastAvailableMB = try values.decodeIfPresent(Double.self, forKey: .leastAvailableMB)
        audioSeconds = try values.decodeIfPresent(Double.self, forKey: .audioSeconds)
        captureSampleRate = try values.decodeIfPresent(Double.self, forKey: .captureSampleRate)
        captureInput = try values.decodeIfPresent(CaptureInput.self, forKey: .captureInput)
        inputLoudestDBFS = try values.decodeIfPresent(Int.self, forKey: .inputLoudestDBFS)
        inputTypicalDBFS = try values.decodeIfPresent(Int.self, forKey: .inputTypicalDBFS)
        preparationMilliseconds = try values.decodeIfPresent(Double.self, forKey: .preparationMilliseconds)
        stopToTextMilliseconds = try values.decodeIfPresent(Double.self, forKey: .stopToTextMilliseconds)
        stopToInsertionMilliseconds = try values.decodeIfPresent(Double.self, forKey: .stopToInsertionMilliseconds)
        textSource = try values.decodeIfPresent(TextSource.self, forKey: .textSource)
        memoryWarnings = try values.decodeIfPresent(Int.self, forKey: .memoryWarnings)
        outcome = try values.decodeIfPresent(Outcome.self, forKey: .outcome)
    }

    /// No outcome yet: it is running, or the keyboard that wrote it went away first.
    var isUnfinished: Bool { outcome == nil }

    /// Unfinished and written by a known keyboard process other than `processID`: that process stopped writing
    /// mid-dictation. A record whose process is unknown is not another's.
    func isUnfinished(byAnotherProcessThan processID: UUID) -> Bool {
        guard isUnfinished, let writer = self.processID else { return false }
        return writer != processID
    }

    /// Whether a write for `attemptID` (anything but the tap's) may replace the record `current` read: only while it
    /// still holds that attempt's id and has not been marked `abandoned`.
    static func mayReplace(_ current: StoreRead<KeyboardDictationRecord>, forAttempt attemptID: UUID) -> Bool {
        guard let current = current.value else { return false }
        return current.attemptID == attemptID && current.outcome != .abandoned
    }

    /// The step reached, with its time and the memory then; the memory is also noted for the peak and the least left.
    mutating func reach(_ step: Step, milliseconds: Double, memory: KeyboardMemorySample) {
        steps.append(StepRecord(step: step, milliseconds: Self.finite(milliseconds), footprintMB: Self.finite(memory.footprintMB),
                                availableMB: Self.finite(memory.availableMB)))
        note(memory)
    }

    /// Notes a sample between steps. Returns whether the least memory left changed.
    @discardableResult
    mutating func note(_ memory: KeyboardMemorySample) -> Bool {
        if let peak = Self.finite(memory.peakMB ?? memory.footprintMB) {
            peakFootprintMB = max(peakFootprintMB ?? peak, peak)
        }
        guard let available = Self.finite(memory.availableMB), available < leastAvailableMB ?? .infinity else { return false }
        leastAvailableMB = available
        return true
    }

    /// The step `ended` and the outcome. After `text` or `noSpeech`, the insertion, offer or drop still adds its step.
    mutating func end(_ outcome: Outcome, milliseconds: Double, memory: KeyboardMemorySample) {
        reach(.ended, milliseconds: milliseconds, memory: memory)
        self.outcome = outcome
    }

    /// A later process found it unfinished: the process that wrote it stopped writing during its last step.
    mutating func markAbandoned() {
        outcome = .abandoned
    }

    /// The last step reached, if any.
    var lastStep: Step? { steps.last?.step }

    /// Every figure finite or unknown: JSONEncoder throws on NaN and infinity, and a failed write would lose the record.
    var sanitized: KeyboardDictationRecord {
        var record = self
        record.peakFootprintMB = Self.finite(peakFootprintMB)
        record.leastAvailableMB = Self.finite(leastAvailableMB)
        record.audioSeconds = Self.finite(audioSeconds)
        record.captureSampleRate = Self.finite(captureSampleRate)
        record.preparationMilliseconds = Self.finite(preparationMilliseconds)
        record.stopToTextMilliseconds = Self.finite(stopToTextMilliseconds)
        record.stopToInsertionMilliseconds = Self.finite(stopToInsertionMilliseconds)
        record.steps = steps.map {
            StepRecord(step: $0.step, milliseconds: Self.finite($0.milliseconds), footprintMB: Self.finite($0.footprintMB),
                       availableMB: Self.finite($0.availableMB))
        }
        return record
    }

    private static func finite(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite ? $0 : nil }
    }
}
#endif
