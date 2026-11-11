import SwiftUI

/// A shortcut drawn as key caps: small raised keys with the glyph on each, and a modifier's side in small words
/// beside its glyph. VoiceOver hears the whole shortcut as one phrase. Without a shortcut it reads "Not set".
public struct KeyCaps: View {
    private let combo: KeyCombo?
    private let size: KeyCapSize
    private let wraps: Bool

    /// Key caps for `combo`, or "Not set" without one. With `wraps`, caps that do not fit the width offered go on
    /// to another line.
    public init(_ combo: KeyCombo?, size: KeyCapSize = .regular, wraps: Bool = false) {
        self.combo = combo
        self.size = size
        self.wraps = wraps
    }

    public var body: some View {
        Group {
            if let combo {
                let caps = ForEach(Array(combo.caps.enumerated()), id: \.offset) { _, cap in
                    KeyCapView(cap: cap, size: size)
                }
                if wraps {
                    FlowLayout(spacing: 3, lineSpacing: 4) { caps }
                } else {
                    HStack(spacing: 3) { caps }
                }
            } else {
                Text("Not set")
                    .font(.system(size: size.fontSize))
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(combo?.spokenLabel ?? String(localized: "Not set"))
    }
}

/// How large key caps are drawn.
public enum KeyCapSize: Sendable {
    /// In a sentence or a menu.
    case small
    /// In a row.
    case regular

    var height: CGFloat { self == .small ? 18 : 22 }
    var fontSize: CGFloat { self == .small ? 10.5 : 12 }
}

private struct KeyCapView: View {
    let cap: KeyCombo.Cap
    let size: KeyCapSize

    var body: some View {
        HStack(spacing: 3) {
            if let side = cap.side {
                Text(side)
                    .font(.system(size: size.fontSize - 2.5, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)
            }
            Text(cap.symbol)
                .font(.system(size: size.fontSize, weight: .medium))
                .foregroundStyle(Theme.ink)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .frame(minWidth: size.height, minHeight: size.height)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.1))
                .shadow(color: .black.opacity(0.6), radius: 0, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5)
        }
    }
}
