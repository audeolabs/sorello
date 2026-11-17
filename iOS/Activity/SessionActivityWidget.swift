import ActivityKit
import SwiftUI
import WidgetKit

/// The widget extension: the session's Live Activity (ARCHITECTURE.md, "Live Activity") in the Dynamic Island and on
/// the Lock Screen, which draws only `SessionActivityState`, the phase, its timers and flags, and reads nothing else;
/// the session control ("Session control"); and the "Voice Note" control ("Voice Note control").
@main
struct SorelloActivityBundle: WidgetBundle {
    var body: some Widget {
        SessionActivityWidget()
        SessionControl()
        VoiceNoteControl()
    }
}

struct SessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(ActivityLook.pill)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state, stale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeading(state: state, isStale: stale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailing(state: state, isStale: stale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottom(state: state, isStale: stale)
                }
            } compactLeading: {
                MarkView(state: state, isStale: stale, width: 20, height: 18)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Sorello")
            } compactTrailing: {
                CompactTrailing(state: state, isStale: stale)
            } minimal: {
                MinimalView(state: state, isStale: stale)
            }
            .keylineTint(ActivityLook.keyline)
        }
    }
}

// MARK: Look

/// Monochrome, like the keyboard's island: white ink on a near-black pill, the brand colours only in the mark's dot,
/// the recording dot, the transcript's glint and a note's last minutes.
enum ActivityLook {
    static let pill = Color(red: 10 / 255, green: 11 / 255, blue: 12 / 255)
    static let keyline = Color.white.opacity(0.12)
    static let aurora = Color(red: 109 / 255, green: 255 / 255, blue: 168 / 255)
    static let glacier = Color(red: 103 / 255, green: 232 / 255, blue: 249 / 255)
    static let coral = Color(red: 255 / 255, green: 125 / 255, blue: 94 / 255)
    static let ember = Color(red: 245 / 255, green: 198 / 255, blue: 107 / 255)
    /// A button's pill on the activity's dark background.
    static let button = Color.white.opacity(0.14)
    static let secondary = Color.white.opacity(0.6)

    /// The mark's dot: aurora while ready or a note is saved, coral while recording (a dictation or a note), glacier
    /// while the transcript is made or a note waits.
    static func accent(_ phase: SessionActivityState.Phase, isStale: Bool) -> Color {
        if isStale { return Color.white.opacity(0.35) }
        switch phase {
        case .ready, .noteSaved: return aurora
        case .recording, .noteRecording: return coral
        case .transcribing, .preparing, .notePreparing, .noteSaving: return glacier
        }
    }

    static func title(_ phase: SessionActivityState.Phase, isStale: Bool) -> String {
        if isStale { return "Session ended" }
        switch phase {
        case .ready: return "Ready to dictate"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .preparing: return "Preparing model"
        case .notePreparing: return "Starting note"
        case .noteRecording: return "Recording note"
        case .noteSaving: return "Saving note"
        case .noteSaved: return "Note saved"
        }
    }

    /// The glyph a note shows where a dictation shows its coral dot.
    static let noteSymbol = "note.text"
}

/// State changes: quick and settled, never a slow fade. None in Always On, where the system draws no animation anyway
/// (`SessionActivityMotion`).
private struct PhaseMotion: ViewModifier {
    let value: SessionActivityState.Phase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    func body(content: Content) -> some View {
        content.animation(SessionActivityMotion.duration(luminanceReduced: isLuminanceReduced).map { .snappy(duration: $0) },
                          value: value)
    }
}

/// A view arriving or leaving as `SessionActivityMotion` says: with Reduce Motion always a cross-fade.
private struct Handover: ViewModifier {
    let kind: (Bool) -> SessionActivityMotion.Handover
    var anchor: UnitPoint = .center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        switch kind(reduceMotion) {
        case .fade: content.transition(.opacity)
        case .push: content.transition(.push(from: .bottom).combined(with: .opacity))
        case .scale(let from): content.transition(.opacity.combined(with: .scale(scale: from, anchor: anchor)))
        }
    }
}

private extension View {
    func phaseMotion(_ phase: SessionActivityState.Phase) -> some View { modifier(PhaseMotion(value: phase)) }
}

/// A change of words slides up a little as it blurs in; with Reduce Motion it only cross-fades.
private struct WordsTransition: ViewModifier {
    func body(content: Content) -> some View {
        content.modifier(Handover(kind: SessionActivityMotion.words))
    }
}

// MARK: The ring mark

/// The ring mark (`RingMark`, KeyboardCore): its seven white dots white at 80%, its state dot in the phase's accent. Once
/// the activity is stale, the dots are white at 45% and the state dot white at 35% (`ActivityLook.accent`), unswollen.
struct MarkView: View {
    let state: SessionActivityState
    let isStale: Bool
    /// Drawn at this size, not whatever the region proposes: island regions can propose odd sizes, and the mark must
    /// never be squeezed or clipped.
    let width: CGFloat
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fitted = RingMark.fitted(in: KeyRect(x: 0, y: 0, width: width, height: height))
        ZStack(alignment: .topLeading) {
            Path { path in
                let r = fitted.whiteRadius
                for dot in fitted.whiteDots {
                    path.addEllipse(in: CGRect(x: dot.x - r, y: dot.y - r, width: 2 * r, height: 2 * r))
                }
            }
            .fill(Color.white.opacity(isStale ? 0.45 : RingMark.whiteStrength))
            Circle()
                .fill(ActivityLook.accent(state.phase, isStale: isStale))
                .frame(width: fitted.stateRadius * 2, height: fitted.stateRadius * 2)
                // The state dot grows a touch while recording: the one sign of life the mark gives (not with Reduce
                // Motion).
                .scaleEffect(SessionActivityMotion.markDotScale(phase: state.phase, isStale: isStale, reduceMotion: reduceMotion))
                .position(x: fitted.stateDot.x, y: fitted.stateDot.y)
        }
        .frame(width: width, height: height)
        .fixedSize()
        .phaseMotion(state.phase)
        .accessibilityHidden(true)
    }
}

// MARK: The dot strip

/// A row of dots, as the keyboard's island draws its wave (`DotWave`): one calm row of equal dots when ready, the voice's
/// swell while recording, and a cool glint of light where the wait's shimmer is (the middle while transcribing, the left
/// third while the model prepares). Every dot is its own view, so a phase change moves each dot's size and brightness
/// rather than swapping pictures: the row swells as recording starts and settles back as it stops. With Reduce Motion
/// the dots keep their size and only their brightness changes (`SessionActivityMotion.dotScale`).
struct DotStrip: View {
    let phase: SessionActivityState.Phase
    let isStale: Bool
    let columns: Int
    let dot: CGFloat
    let gap: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: gap) {
            ForEach(0 ..< columns, id: \.self) { column in
                let u = columns > 1 ? Double(column) / Double(columns - 1) : 0.5
                let lit = StripPattern.lit(phase: isStale ? .ready : phase, u: u)
                Circle()
                    .fill(StripPattern.color(phase: phase, u: u, isStale: isStale))
                    .opacity((isStale ? 0.6 : 1) * (DotWave.restBrightness + (1 - DotWave.restBrightness) * lit))
                    .scaleEffect(SessionActivityMotion.dotScale(lit: lit, reduceMotion: reduceMotion))
                    .frame(width: dot, height: dot)
            }
        }
        .phaseMotion(phase)
        .accessibilityHidden(true)
    }
}

/// How much a phase lifts the strip's dot `u` of the way along it, from 0 (at rest) to 1, and its colour, with the
/// keyboard's own shapes (`DotWave.lift`, `DotWave.glow`). Live Activities draw no continuous animation, so each phase is
/// one still moment of the keyboard's motion.
enum StripPattern {
    static func lit(phase: SessionActivityState.Phase, u: Double) -> Double {
        switch phase {
        case .ready, .noteSaved: return 0
        case .recording, .noteRecording: return DotWave.stillLift(at: u)
        case .transcribing, .preparing, .notePreparing, .noteSaving: return DotWave.glow(at: u, sweep: glint(phase))
        }
    }

    static func color(phase: SessionActivityState.Phase, u: Double, isStale: Bool) -> Color {
        guard !isStale, isWait(phase) else { return .white }
        // The wait's glint: a little glacier where the light gathers.
        return DotWave.glow(at: u, sweep: glint(phase)) > 0.45 ? ActivityLook.glacier : .white
    }

    private static func isWait(_ phase: SessionActivityState.Phase) -> Bool {
        phase == .transcribing || phase == .preparing || phase == .notePreparing || phase == .noteSaving
    }

    /// Where the light gathers while the transcript is made or a note saves: the middle, or the left third while the
    /// model prepares, for a dictation or a note.
    private static func glint(_ phase: SessionActivityState.Phase) -> Double {
        phase == .preparing || phase == .notePreparing ? 0.3 : 0.5
    }
}

// MARK: Timers

/// The recording's elapsed time, counting up from its start; or a ready session's time left. Live timers are the only
/// thing that moves between updates. The host cuts a dictation off at five minutes and the activity is stale soon
/// after, so the hour's bound is never reached. A note's time shows its hours: ActivityKit ends the activity after
/// eight, so the bound is never reached either.
private struct PhaseTimer: View {
    let state: SessionActivityState

    var body: some View {
        switch state.phase {
        case .recording:
            let since = state.since ?? .now
            Text(timerInterval: since ... since.addingTimeInterval(3600), countsDown: false, showsHours: false)
        case .noteRecording:
            let since = state.since ?? .now
            Text(timerInterval: since ... since.addingTimeInterval(9 * 3600), countsDown: false, showsHours: true)
        case .ready:
            if let endsAt = state.endsAt {
                Text(timerInterval: min(Date.now, endsAt) ... endsAt, countsDown: true, showsHours: false)
            }
        case .transcribing, .preparing, .notePreparing, .noteSaving, .noteSaved:
            EmptyView()
        }
    }

    /// The phases with a live timer.
    static func shows(_ state: SessionActivityState) -> Bool {
        state.phase == .recording || state.phase == .noteRecording || (state.phase == .ready && state.endsAt != nil)
    }
}

/// A voice note's time left on battery, beside the timer glyph and in ember for its last minutes; or, with power
/// connected, a bolt and "Charging", with no countdown. `tail`: the words after the time ("left" on the Lock Screen).
private struct VoiceNoteLimit: View {
    let state: SessionActivityState
    let size: CGFloat
    var tail: String?

    var body: some View {
        if state.onPower == true {
            HStack(spacing: 4) {
                Image(systemName: SessionActivityState.chargingSymbol)
                    .font(.system(size: size, weight: .semibold))
                Text(SessionActivityState.chargingWords)
            }
            .foregroundStyle(ActivityLook.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SessionActivityState.chargingSpoken)
        } else if let endsAt = state.endsAt {
            let ink = state.lastMinutes == true ? ActivityLook.ember : ActivityLook.secondary
            HStack(spacing: 5) {
                Image(systemName: SessionActivityState.countdownSymbol)
                    .font(.system(size: size, weight: .semibold))
                    .accessibilityLabel(SessionActivityState.noteCountdownSpokenLead)
                let time = Text(timerInterval: min(Date.now, endsAt) ... endsAt, countsDown: true, showsHours: true)
                if let tail { Text("\(time) \(tail)") } else { time }
            }
            .foregroundStyle(ink)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The voice note's button on the Lock Screen and in the expanded island: Stop while a note prepares or records, Note
/// while the session is ready and a vault exists, none on a stale activity. Its intent runs in the app.
private struct VoiceNoteButton: View {
    let state: SessionActivityState
    let isStale: Bool

    var body: some View {
        if !isStale, state.isNoteInProgress {
            Button(intent: StopVoiceNoteIntent()) {
                label("Stop", symbol: "stop.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop voice note")
        } else if !isStale, state.phase == .ready, state.offersNote == true {
            Button(intent: StartVoiceNoteIntent()) {
                label("Note", symbol: "plus")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start a voice note")
        }
    }

    static func shows(_ state: SessionActivityState, isStale: Bool) -> Bool {
        !isStale && (state.isNoteInProgress || (state.phase == .ready && state.offersNote == true))
    }

    private func label(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
            Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(ActivityLook.button))
        .fixedSize()
    }
}

/// The ready session's countdown glyph, standing for "Session ends in … if idle", which VoiceOver reads as those
/// words.
private struct CountdownGlyph: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: SessionActivityState.countdownSymbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(ActivityLook.secondary)
            .accessibilityLabel(SessionActivityState.countdownSpokenLead)
    }
}

// MARK: Dynamic Island

private struct CompactTrailing: View {
    let state: SessionActivityState
    let isStale: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            if state.phase == .recording && !isStale {
                HStack(spacing: 4) {
                    Circle().fill(ActivityLook.coral).frame(width: 6, height: 6)
                        .accessibilityLabel(ActivityLook.title(state.phase, isStale: isStale))
                    PhaseTimer(state: state)
                        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 34, alignment: .trailing)
                }
                .modifier(WordsTransition())
            } else if state.phase == .noteRecording && !isStale {
                // A note, never mistaken for a dictation: its glyph where a dictation has the coral dot.
                HStack(spacing: 4) {
                    Image(systemName: ActivityLook.noteSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .accessibilityLabel(ActivityLook.title(state.phase, isStale: isStale))
                    PhaseTimer(state: state)
                        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .fixedSize()
                        .frame(minWidth: 34, alignment: .trailing)
                }
                .modifier(WordsTransition())
            } else {
                DotStrip(phase: state.phase, isStale: isStale, columns: 6, dot: 4, gap: 1.6)
                    .frame(width: 34)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(ActivityLook.title(state.phase, isStale: isStale))
                    .modifier(Handover(kind: SessionActivityMotion.compactTrailing, anchor: .trailing))
            }
        }
        .phaseMotion(state.phase)
    }
}

private struct MinimalView: View {
    let state: SessionActivityState
    let isStale: Bool

    var body: some View {
        ZStack {
            if state.phase == .recording && !isStale {
                Circle().fill(ActivityLook.coral).frame(width: 9, height: 9)
                    .modifier(Handover(kind: SessionActivityMotion.minimalDot))
            } else if state.phase == .noteRecording && !isStale {
                Image(systemName: ActivityLook.noteSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ActivityLook.coral)
                    .modifier(Handover(kind: SessionActivityMotion.minimalDot))
            } else {
                MarkView(state: state, isStale: isStale, width: 18, height: 16)
                    .transition(.opacity)
            }
        }
        .phaseMotion(state.phase)
        // The one element VoiceOver reads here: what the session is doing.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sorello, \(ActivityLook.title(state.phase, isStale: isStale))")
    }
}

private struct ExpandedLeading: View {
    let state: SessionActivityState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 7) {
            MarkView(state: state, isStale: isStale, width: 24, height: 22)
            Text("Sorello")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.leading, 4)
    }
}

private struct ExpandedTrailing: View {
    let state: SessionActivityState
    let isStale: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            if !isStale, PhaseTimer.shows(state) {
                HStack(spacing: 5) {
                    if state.phase == .recording {
                        Circle().fill(ActivityLook.coral).frame(width: 7, height: 7)
                    } else if state.phase == .noteRecording {
                        Image(systemName: ActivityLook.noteSymbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ActivityLook.coral)
                            .accessibilityLabel(ActivityLook.title(state.phase, isStale: isStale))
                    } else {
                        CountdownGlyph(size: 13)
                    }
                    PhaseTimer(state: state)
                        .foregroundStyle(.white)
                        .fixedSize()
                        .frame(minWidth: 40, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .id(state.phase)
                .modifier(WordsTransition())
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.trailing, 4)
        .phaseMotion(state.phase)
    }
}

private struct ExpandedBottom: View {
    let state: SessionActivityState
    let isStale: Bool

    var body: some View {
        VStack(spacing: 10) {
            DotStrip(phase: state.phase, isStale: isStale, columns: 25, dot: 7, gap: 5)
                .frame(maxWidth: .infinity, minHeight: 14)
            if VoiceNoteButton.shows(state, isStale: isStale) || (state.isNote && !isStale) {
                // A note's name and its limit on one side, its button on the other.
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        if state.isNoteInProgress {
                            VoiceNoteLimit(state: state, size: 11)
                                .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    VoiceNoteButton(state: state, isStale: isStale)
                }
                .padding(.horizontal, 6)
            } else {
                title
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .phaseMotion(state.phase)
    }

    private var title: some View {
        Text(ActivityLook.title(state.phase, isStale: isStale))
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(ActivityLook.secondary)
            .id(isStale ? "stale" : state.phase.rawValue)
            .modifier(WordsTransition())
    }
}

// MARK: Lock Screen

struct LockScreenView: View {
    let state: SessionActivityState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                MarkView(state: state, isStale: isStale, width: 30, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ActivityLook.title(state.phase, isStale: isStale))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .id(isStale ? "stale" : state.phase.rawValue)
                        .modifier(WordsTransition())
                    // One line in every phase, so the panel keeps its height as the phase changes.
                    subtitle
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .font(.system(size: 14, weight: .regular, design: .rounded).monospacedDigit())
                        .foregroundStyle(ActivityLook.secondary)
                }
                Spacer(minLength: 0)
                if (state.phase == .recording || state.phase == .noteRecording) && !isStale {
                    HStack(spacing: 6) {
                        if state.phase == .recording {
                            Circle().fill(ActivityLook.coral).frame(width: 8, height: 8)
                        } else {
                            Image(systemName: ActivityLook.noteSymbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(ActivityLook.coral)
                                .accessibilityHidden(true)
                        }
                        PhaseTimer(state: state)
                            .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .fixedSize()
                            .frame(minWidth: 52, alignment: .trailing)
                    }
                    .modifier(WordsTransition())
                }
            }
            if VoiceNoteButton.shows(state, isStale: isStale) {
                // A shorter strip beside the button.
                HStack(spacing: 14) {
                    DotStrip(phase: state.phase, isStale: isStale, columns: 17, dot: 7, gap: 5)
                        .frame(minHeight: 14)
                    Spacer(minLength: 0)
                    VoiceNoteButton(state: state, isStale: isStale)
                }
            } else {
                DotStrip(phase: state.phase, isStale: isStale, columns: 27, dot: 7, gap: 5)
                    .frame(maxWidth: .infinity, minHeight: 14)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .phaseMotion(state.phase)
    }

    @ViewBuilder private var subtitle: some View {
        if isStale {
            Text("Open Sorello to start a new one")
        } else {
            switch state.phase {
            case .ready:
                if let endsAt = state.endsAt {
                    HStack(spacing: 5) {
                        CountdownGlyph(size: 12)
                        Text("\(Text(timerInterval: min(Date.now, endsAt) ... endsAt, countsDown: true, showsHours: false)) \(SessionActivityState.lockScreenCountdownTail)")
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Text("Dictation session")
                }
            case .recording: Text("Tap Stop on the keyboard when done")
            case .transcribing: Text("Your words land in a moment")
            case .preparing: Text("The first dictation takes a little longer")
            case .notePreparing: Text("Nothing is recorded yet")
            case .noteRecording: VoiceNoteLimit(state: state, size: 12, tail: SessionActivityState.lockScreenCountdownTail)
            case .noteSaving: Text("Writing the last words")
            case .noteSaved: Text(state.atLimit == true ? "Stopped at its time limit" : "Kept in your notes")
            }
        }
    }
}
