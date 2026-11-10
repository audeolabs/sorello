import SwiftUI

/// What the Run Log asks of the app layer.
public struct RunLogActions {
    public var play: (_ id: String) -> Void
    public var stop: () -> Void
    /// Transcribes the entry's audio again with today's dictionary and rules and replaces its text. Never pastes.
    public var retry: (_ id: String) -> Void
    public var copy: (_ id: String) -> Void
    public var delete: (_ id: String) -> Void
    /// Deletes every entry and its audio; the session forgets the last dictation.
    public var clearAll: () -> Void
    /// Turns the Run Log back on, from its "off" state.
    public var turnOn: () -> Void

    public init(play: @escaping (String) -> Void = { _ in }, stop: @escaping () -> Void = {},
                retry: @escaping (String) -> Void = { _ in }, copy: @escaping (String) -> Void = { _ in },
                delete: @escaping (String) -> Void = { _ in }, clearAll: @escaping () -> Void = {},
                turnOn: @escaping () -> Void = {}) {
        self.play = play
        self.stop = stop
        self.retry = retry
        self.copy = copy
        self.delete = delete
        self.clearAll = clearAll
        self.turnOn = turnOn
    }
}

/// The Run Log's values.
@Observable
public final class RunLogModel {
    /// Newest first; at most 20.
    public var items: [RunLogItem]
    /// The entry whose audio is playing.
    public var playingID: String?
    /// Entries being transcribed again.
    public var retryingIDs: Set<String>
    /// Whether the Run Log keeps dictations at all.
    public var isEnabled: Bool
    /// The time relative labels are measured from; nil follows the clock, minute by minute. Snapshots fix it.
    public var referenceDate: Date?
    /// The calendar and locale times are written in: the user's, except in snapshots.
    public var calendar: Calendar
    public var locale: Locale
    public var actions: RunLogActions

    public init(items: [RunLogItem], playingID: String? = nil, retryingIDs: Set<String> = [], isEnabled: Bool = true,
                referenceDate: Date? = nil, calendar: Calendar = .autoupdatingCurrent,
                locale: Locale = .autoupdatingCurrent, actions: RunLogActions = RunLogActions()) {
        self.calendar = calendar
        self.locale = locale
        self.items = items
        self.playingID = playingID
        self.retryingIDs = retryingIDs
        self.isEnabled = isEnabled
        self.referenceDate = referenceDate
        self.actions = actions
    }
}

/// Run Log: the last 20 dictations with their audio, to play, transcribe again, copy or delete. It all stays on
/// this Mac.
public struct RunLogScreen: View {
    private let model: RunLogModel
    @State private var confirmingClear = false

    public init(model: RunLogModel) {
        self.model = model
    }

    public var body: some View {
        ScreenPage(String(localized: "Run Log"),
                   subtitle: String(localized: "Your last 20 dictations, with their audio. Everything here stays on this Mac."),
                   trailing: {
                       Button(String(localized: "Clear All…")) { confirmingClear = true }
                           .buttonStyle(QuietButtonStyle(destructive: true))
                           .disabled(model.items.isEmpty)
                           .opacity(model.items.isEmpty ? 0 : 1)
                           .accessibilityHidden(model.items.isEmpty)
                   }) {
            if !model.isEnabled {
                EmptyState(symbol: "clock.badge.xmark", title: String(localized: "The Run Log is off"),
                           message: String(localized: "Dictations are not kept. Turn it on to keep the last 20, with their audio, on this Mac.")) {
                    Button(String(localized: "Turn On"), action: model.actions.turnOn)
                        .buttonStyle(PrimaryButtonStyle())
                }
            } else if model.items.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: String(localized: "No dictations yet"),
                           message: String(localized: "Each dictation appears here with its audio, so you can play it, copy it, or transcribe it again."))
            } else {
                TimelineView(.everyMinute) { context in
                    Card(dividerInset: Metrics.rowInset + 28 + 12) {
                        ForEach(model.items) { item in
                            RunLogRow(item: item, now: model.referenceDate ?? context.date, calendar: model.calendar,
                                      locale: model.locale,
                                      isPlaying: model.playingID == item.id,
                                      isRetrying: model.retryingIDs.contains(item.id), actions: model.actions)
                        }
                    }
                }
            }
        }
        .confirmationDialog(String(localized: "Clear the Run Log?"), isPresented: $confirmingClear,
                            titleVisibility: .visible) {
            Button(String(localized: "Clear All"), role: .destructive, action: model.actions.clearAll)
        } message: {
            Text("Every dictation and its audio are deleted from this Mac. This can’t be undone.")
        }
    }
}

/// One dictation: play or stop, its words, when and how it ended, and its actions. While it is transcribed again,
/// a glacier line takes the place of its details and its actions wait.
private struct RunLogRow: View {
    let item: RunLogItem
    let now: Date
    let calendar: Calendar
    let locale: Locale
    let isPlaying: Bool
    let isRetrying: Bool
    let actions: RunLogActions
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { isPlaying ? actions.stop() : actions.play(item.id) } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .offset(x: isPlaying ? 0 : 1)
            }
            .buttonStyle(IconButtonStyle(diameter: 28, island: true))
            .accessibilityLabel(isPlaying ? String(localized: "Stop") : String(localized: "Play"))
            .accessibilityHint(String(localized: "The recording of this dictation"))
            VStack(alignment: .leading, spacing: 5) {
                words
                details
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            HStack(spacing: 2) {
                Button { actions.retry(item.id) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel(String(localized: "Transcribe again"))
                    .accessibilityHint(String(localized: "Replaces the text. Nothing is pasted."))
                    .help(String(localized: "Transcribe again"))
                Button {
                    actions.copy(item.id)
                    flashCopied()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(IconButtonStyle())
                .disabled(!item.canCopy)
                .accessibilityLabel(copied ? String(localized: "Copied") : String(localized: "Copy"))
                .help(String(localized: "Copy"))
                Button { actions.delete(item.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(IconButtonStyle(destructive: true))
                    .accessibilityLabel(String(localized: "Delete"))
                    .help(String(localized: "Delete"))
            }
            .disabled(isRetrying)
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.vertical, 11)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var words: some View {
        switch item.display {
        case .text(let text):
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .commandOnly(let heard):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
                    .accessibilityHidden(true)
                Text(verbatim: "“\(heard)”")
                    .font(.system(size: 13).italic())
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(1)
                Text("Only a command, nothing pasted")
                    .font(.rowDetail)
                    .foregroundStyle(Theme.secondaryInk)
            }
        case .none:
            Text("No text")
                .font(.system(size: 13).italic())
                .foregroundStyle(Theme.secondaryInk)
        }
    }

    @ViewBuilder
    private var details: some View {
        if isRetrying {
            HStack(spacing: 8) {
                GlacierBar().frame(width: 80)
                Text("Transcribing again…")
            }
            .font(.rowDetail)
            .foregroundStyle(Theme.secondaryInk)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Transcribing again"))
        } else {
            HStack(spacing: 6) {
                Text(RunLogTime.label(for: item.date, now: now, calendar: calendar, locale: locale))
                Text(verbatim: "·").accessibilityHidden(true)
                HStack(spacing: 3) {
                    if item.outcome.isProblem {
                        StatusIndicator(.problem, size: 7)
                    }
                    Text(item.outcome.label)
                }
                Text(verbatim: "·").accessibilityHidden(true)
                Text(item.durationLabel).monospacedDigit()
                    .accessibilityLabel(String(localized: "\(item.durationLabel) long"))
            }
            .font(.rowDetail)
            .foregroundStyle(Theme.secondaryInk)
            .lineLimit(1)
        }
    }

    private func flashCopied() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { copied = false }
        }
    }
}
