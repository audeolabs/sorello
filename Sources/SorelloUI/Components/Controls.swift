import SwiftUI

/// A small capsule naming one thing, such as an app a word is limited to. With `onRemove`, it ends in a ✕ that
/// removes it.
public struct Chip: View {
    private let title: String
    private let symbol: String?
    private let onRemove: (() -> Void)?
    @State private var hovering = false

    public init(_ title: String, symbol: String? = nil, onRemove: (() -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
            }
            Text(title).lineLimit(1).truncationMode(.middle)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(hovering ? Color.white.opacity(0.14) : .clear))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityLabel(String(localized: "Remove \(title)"))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.ink)
        .padding(.leading, 8)
        .padding(.trailing, onRemove == nil ? 8 : 3)
        .frame(height: 20)
        .background(Capsule().fill(Theme.controlFill))
        .overlay(Pill().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}

/// A choice among a few values, as a row of segments on the island's track. The chosen segment is lifted in white;
/// the others are secondary ink. Each segment is a button VoiceOver reads with its selected state.
public struct PresetPicker<Value: Hashable>: View {
    private let options: [Value]
    @Binding private var selection: Value
    private let label: (Value) -> String
    private let spokenLabel: (Value) -> String
    private let title: String
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ title: String, options: [Value], selection: Binding<Value>, label: @escaping (Value) -> String,
                spokenLabel: ((Value) -> String)? = nil) {
        self.title = title
        self.options = options
        _selection = selection
        self.label = label
        self.spokenLabel = spokenLabel ?? label
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                PresetSegment(title: label(option), isSelected: option == selection, namespace: namespace) {
                    selection = option
                }
                .accessibilityLabel(spokenLabel(option))
                .accessibilityAddTraits(option == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .islandSurface()
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.88), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct PresetSegment: View {
    let title: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium).monospacedDigit())
                .foregroundStyle(isSelected || hovering ? Theme.ink : Theme.secondaryInk)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(minWidth: 38, minHeight: 22)
                .background {
                    if isSelected {
                        Capsule().fill(Color.white.opacity(0.16)).matchedGeometryEffect(id: "selection", in: namespace)
                    } else if hovering {
                        Capsule().fill(Theme.hover)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .focusRing(Pill(), isFocused: focused)
        .onHover { hovering = $0 }
    }
}

/// A text field on the island's surface, with a white edge while it has focus and an ember edge while what it
/// holds has a problem. The placeholder is secondary ink, so it stays legible.
public struct SorelloTextField: View {
    private let placeholder: String
    @Binding private var text: String
    private let hasProblem: Bool
    private let onSubmit: () -> Void
    @FocusState private var focused: Bool

    public init(_ placeholder: String, text: Binding<String>, hasProblem: Bool = false, onSubmit: @escaping () -> Void = {}) {
        self.placeholder = placeholder
        _text = text
        self.hasProblem = hasProblem
        self.onSubmit = onSubmit
    }

    public var body: some View {
        TextField(text: $text, prompt: Text(placeholder).foregroundStyle(Theme.secondaryInk)) {
            Text(placeholder)
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(Theme.ink)
        .focused($focused)
        .onSubmit(onSubmit)
        .padding(.horizontal, 10)
        .frame(height: Metrics.fieldHeight)
        .background(Theme.pill, in: RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
                .strokeBorder(edge, lineWidth: focused || hasProblem ? 1 : 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private var edge: Color {
        if hasProblem { return Theme.ember }
        return focused ? Color.white.opacity(0.7) : Theme.edge
    }
}

/// A message under a field: the ember symbol, then words in white, so a problem never relies on colour alone.
public struct InlineMessage: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.ember)
                .accessibilityHidden(true)
            Text(text)
                .font(.rowDetail)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What a list shows while it has nothing in it: a glyph, a title, a sentence, and perhaps the action that fills it.
public struct EmptyState<Action: View>: View {
    private let symbol: String
    private let title: String
    private let message: String
    private let action: Action

    public init(symbol: String, title: String, message: String, @ViewBuilder action: () -> Action) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.action = action()
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
            action.padding(.top, 6)
        }
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }
}

public extension EmptyState where Action == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}
