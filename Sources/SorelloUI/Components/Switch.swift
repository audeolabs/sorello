import SwiftUI

/// A switch in Sorello's colours: the toggle green when on, a quiet track when off, and a white knob either way.
/// The label sits on the leading side and the switch on the trailing side, as in the Mac's Settings. The switch
/// keeps the system toggle's meaning for VoiceOver and the keyboard: Space flips it when it has focus.
public struct SorelloSwitchStyle: ToggleStyle {
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
            .overlay(Capsule().strokeBorder(Color.white.opacity(isOn ? 0 : 0.1), lineWidth: 0.5))
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: width, height: height)
            .focusRing(Capsule(), isFocused: focused)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
            .onTapGesture { if isEnabled { isOn.toggle() } }
            .focusable(isEnabled)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.space) {
                isOn.toggle()
                return .handled
            }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.85), value: isOn)
    }
}

public extension ToggleStyle where Self == SorelloSwitchStyle {
    /// Sorello's switch.
    static var sorello: SorelloSwitchStyle { SorelloSwitchStyle() }
}
