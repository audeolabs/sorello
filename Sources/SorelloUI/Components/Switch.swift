import SwiftUI

/// A switch in Sorello's colours: the toggle green when on, a quiet track when off, and a white knob either way.
/// The label sits on the leading side and the switch on the trailing side, as in the Mac's Settings. The switch
/// keeps the system toggle's meaning for VoiceOver and the keyboard: Space flips it when it has focus.
public struct SorelloSwitchStyle: ToggleStyle {
    /// Sorello's switch.
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Metrics.glyphGap) {
            configuration.label
            Spacer(minLength: 8)
            SwitchKnob(isOn: configuration.$isOn)
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

private struct SwitchKnob: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hovering = false

    private let width: CGFloat = 32
    private let height: CGFloat = 19

    var body: some View {
        Capsule()
            .fill(isOn ? Theme.toggle : Color.white.opacity(hovering && isEnabled ? 0.2 : 0.14))
            .overlay(Pill().strokeBorder(Color.white.opacity(isOn ? 0 : 0.1), lineWidth: 0.5))
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: width, height: height)
            .focusRing(Pill(), isFocused: focused)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
            .onTapGesture { if isEnabled { isOn.toggle() } }
            .focusable(isEnabled)
            .focused($focused)
            #if SORELLO_LEGACY
            .modifier(SpaceToggles(isOn: $isOn))
            #else
            .focusEffectDisabled()
            .onKeyPress(.space) {
                isOn.toggle()
                return .handled
            }
            #endif
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.85), value: isOn)
    }
}

/// `.toggleStyle(.sorello)`.
public extension ToggleStyle where Self == SorelloSwitchStyle {
    /// Sorello's switch.
    static var sorello: SorelloSwitchStyle { SorelloSwitchStyle() }
}

#if SORELLO_LEGACY
/// The switch's keyboard half in the build for older Macs: Space toggles it and the system draws no focus ring of
/// its own, from macOS 14, as in the usual build. macOS 13 has neither call, so there the switch keeps the system's
/// focus ring and is changed by clicking.
private struct SpaceToggles: ViewModifier {
    @Binding var isOn: Bool

    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content
                .focusEffectDisabled()
                .onKeyPress(.space) {
                    isOn.toggle()
                    return .handled
                }
        } else {
            content
        }
    }
}
#endif
