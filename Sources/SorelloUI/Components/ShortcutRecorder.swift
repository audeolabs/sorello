import SwiftUI

/// What a shortcut recorder asks of the app layer, which drives the shortcut adapter's recording.
public struct ShortcutRecorderActions {
    /// Start listening for the next key or set of modifiers for this action.
    public var record: (ShortcutKind) -> Void
    /// Stop listening and keep the shortcut as it was.
    public var cancel: (ShortcutKind) -> Void
    /// Leave the action without a shortcut (Tap to Toggle and Paste Again), or put Hold to Talk back to fn.
    public var clear: (ShortcutKind) -> Void

    /// Actions that each do nothing unless given.
    public init(record: @escaping (ShortcutKind) -> Void = { _ in }, cancel: @escaping (ShortcutKind) -> Void = { _ in },
                clear: @escaping (ShortcutKind) -> Void = { _ in }) {
        self.record = record
        self.cancel = cancel
        self.clear = clear
    }
}

/// One action's shortcut: its name and what it does, then a well showing the keys as key caps. Clicking the well
/// records new keys; while it records it says so and offers Cancel. A refused attempt is explained under the row.
public struct ShortcutRecorderRow: View {
    private let kind: ShortcutKind
    private let state: ShortcutRecorderState
    private let actions: ShortcutRecorderActions

    /// The recorder for `kind` in `state`.
    public init(_ kind: ShortcutKind, state: ShortcutRecorderState, actions: ShortcutRecorderActions) {
        self.kind = kind
        self.state = state
        self.actions = actions
    }

    /// A shortcut of more than five keys takes the row's full width under the words, its caps wrapping, so even
    /// the longest (fn with both sides of every modifier) fits in setup's narrow card.
    private var isLong: Bool { (state.keys?.caps.count ?? 0) > 5 }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLong {
                RowWords(title: kind.title, detail: kind.detail)
                HStack(alignment: .center, spacing: Metrics.glyphGap) {
                    RecorderWell(kind: kind, state: state, actions: actions, stretches: true)
                    clearButton
                }
            } else {
                HStack(alignment: .center, spacing: Metrics.glyphGap) {
                    RowWords(title: kind.title, detail: kind.detail)
                    Spacer(minLength: 12)
                    RecorderWell(kind: kind, state: state, actions: actions, stretches: false)
                    clearButton
                }
            }
            if let refusal = state.refusal {
                InlineMessage(refusal.message)
                    .transition(.opacity)
            }
        }
        .rowPadding()
        // A recorder left listening would keep every shortcut silent after its screen or step has gone.
        .onDisappear {
            if state.isRecording { actions.cancel(kind) }
        }
    }

    /// ✕ for an action that can be unset; for Hold to Talk, a way back to fn once it is something else.
    @ViewBuilder
    private var clearButton: some View {
        if kind.canBeUnset {
            Button { actions.clear(kind) } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(diameter: 22))
                .disabled(state.keys == nil || state.isRecording)
                .opacity(state.keys == nil ? 0 : 1)
                .accessibilityHidden(state.keys == nil)
                .accessibilityLabel(String(localized: "Clear \(kind.title) shortcut"))
        } else {
            Button { actions.clear(kind) } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(IconButtonStyle(diameter: 22))
                .disabled(state.keys == .function || state.isRecording)
                .opacity(state.keys == .function ? 0 : 1)
                .accessibilityHidden(state.keys == .function)
                .accessibilityLabel(String(localized: "Use fn for \(kind.title)"))
        }
    }
}

private struct RecorderWell: View {
    let kind: ShortcutKind
    let state: ShortcutRecorderState
    let actions: ShortcutRecorderActions
    /// Takes the width it is offered and wraps its caps, rather than growing to fit them on one line.
    let stretches: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            state.isRecording ? actions.cancel(kind) : actions.record(kind)
        } label: {
            HStack(spacing: 8) {
                if state.isRecording {
                    StatusIndicator(.preparing, size: 7)
                    Text("Press keys…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryInk)
                        .accessibilityHidden(true)
                } else {
                    KeyCaps(state.keys, size: (state.keys?.caps.count ?? 0) > 4 ? .small : .regular, wraps: stretches)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, stretches ? 5 : 0)
            .frame(minWidth: 148, maxWidth: stretches ? .infinity : nil, minHeight: 30, alignment: .leading)
            .fixedSize(horizontal: !stretches, vertical: true)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering && !state.isRecording ? Color.white.opacity(0.05) : .clear))
            .background(Theme.pill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(state.isRecording ? Theme.glacier.opacity(0.8) : Theme.edge,
                                  lineWidth: state.isRecording ? 1 : 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(RecorderWellStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(String(localized: "\(kind.title) shortcut"))
        .accessibilityValue(state.isRecording ? String(localized: "Recording. Press the new keys.")
                            : (state.keys?.spokenLabel ?? String(localized: "Not set")))
        .accessibilityHint(state.isRecording ? String(localized: "Cancels recording")
                           : String(localized: "Records a new shortcut"))
    }
}

private struct RecorderWellStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RecorderWellBody(configuration: configuration)
    }
}

private struct RecorderWellBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .focusRing(RoundedRectangle(cornerRadius: 8, style: .continuous), isFocused: isFocused)
    }
}
