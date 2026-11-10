import SwiftUI

/// How tall a button is drawn.
public enum ButtonSize: Sendable {
    /// Inside a row, beside its words.
    case compact
    /// In a card or a panel.
    case regular
    /// Setup's main action.
    case large

    var height: CGFloat {
        switch self {
        case .compact: 24
        case .regular: 30
        case .large: 38
        }
    }

    var font: Font {
        switch self {
        case .compact: .system(size: 12, weight: .medium)
        case .regular: .system(size: 13, weight: .semibold)
        case .large: .system(size: 14, weight: .semibold)
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .compact: 12
        case .regular: 16
        case .large: 24
        }
    }
}

/// The main action: the island's near-black capsule with its hairline and white words, the accent only on its
/// glyph. It lifts a little under the pointer, dims while pressed, and dims to 45% when disabled.
public struct PrimaryButtonStyle: ButtonStyle {
    public var size: ButtonSize
    /// The glyph's colour, when the label has one and it shows a state.
    public var accent: Color?

    public init(size: ButtonSize = .regular, accent: Color? = nil) {
        self.size = size
        self.accent = accent
    }

    public func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, size: size, accent: accent)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: ButtonSize
    let accent: Color?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        configuration.label
            .labelStyle(AccentGlyphLabelStyle(accent: accent))
            .font(size.font)
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.height)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .background(Capsule().fill(Color.white.opacity(hovering && isEnabled ? 0.07 : 0)))
            .islandSurface()
            .contentShape(Capsule())
            .focusRing(Capsule(), isFocused: isFocused)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// A quieter action beside the main one: words only, in secondary ink, turning white under the pointer. With
/// `destructive`, the words are coral, the one place that colour appears.
public struct QuietButtonStyle: ButtonStyle {
    public var size: ButtonSize
    public var destructive: Bool

    public init(size: ButtonSize = .regular, destructive: Bool = false) {
        self.size = size
        self.destructive = destructive
    }

    public func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, size: size, destructive: destructive)
    }
}

private struct QuietButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: ButtonSize
    let destructive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    var body: some View {
        configuration.label
            .labelStyle(AccentGlyphLabelStyle(accent: nil))
            .font(size == .compact ? .system(size: 12, weight: .medium) : .system(size: 13, weight: .medium))
            .foregroundStyle(destructive ? Theme.coral : (hovering && isEnabled ? Theme.ink : Theme.secondaryInk))
            .lineLimit(1)
            .padding(.horizontal, size == .compact ? 8 : 12)
            .frame(minHeight: size.height)
            .background(Capsule().fill(hovering && isEnabled ? Theme.hover : .clear))
            .contentShape(Capsule())
            .focusRing(Capsule(), isFocused: isFocused)
            .opacity(configuration.isPressed ? 0.6 : (isEnabled ? 1 : 0.45))
            .onHover { hovering = $0 }
    }
}

/// A control that is only a glyph (copy, play, delete): a round target that lights under the pointer. `island`
/// draws it on the island's surface, for the one glyph that leads a row; `destructive` turns the glyph coral under
/// the pointer. Every use gives it an accessibility label, because the glyph has no words.
public struct IconButtonStyle: ButtonStyle {
    public var diameter: CGFloat
    public var island: Bool
    public var destructive: Bool

    public init(diameter: CGFloat = 26, island: Bool = false, destructive: Bool = false) {
        self.diameter = diameter
        self.island = island
        self.destructive = destructive
    }

    public func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, diameter: diameter, island: island, destructive: destructive)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let diameter: CGFloat
    let island: Bool
    let destructive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    private var ink: Color {
        guard isEnabled else { return Theme.secondaryInk }
        if hovering { return destructive ? Theme.coral : Theme.ink }
        return island ? Theme.ink : Theme.secondaryInk
    }

    var body: some View {
        let face = configuration.label
            .font(.system(size: diameter * 0.46, weight: .semibold))
            .foregroundStyle(ink)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(hovering && isEnabled ? Theme.hover : .clear))
        Group {
            if island { face.islandSurface(Circle()) } else { face }
        }
        .contentShape(Circle())
        .focusRing(Circle(), isFocused: isFocused)
        .opacity(configuration.isPressed ? 0.6 : (isEnabled ? 1 : 0.4))
        .onHover { hovering = $0 }
    }
}

/// A label whose glyph takes an accent, when there is one, and whose words stay in the button's ink.
struct AccentGlyphLabelStyle: LabelStyle {
    var accent: Color?

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .foregroundStyle(accent.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
                .accessibilityHidden(true)
            configuration.title
        }
    }
}
