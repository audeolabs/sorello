import DesignCore
import SwiftUI

/// The mark of a state: an aurora dot for ready, a glacier dot that breathes softly while preparing, a grey dot for
/// neutral, and an ember warning symbol, never a dot, for a problem. Decorative: the words beside it carry the state.
public struct StatusIndicator: View {
    private let indicator: StatusLine.Indicator
    private let size: CGFloat

    /// The mark for `indicator`, its dot `size` points across.
    public init(_ indicator: StatusLine.Indicator, size: CGFloat = 8) {
        self.indicator = indicator
        self.size = size
    }

    public var body: some View {
        Group {
            switch indicator {
            case .ready: Circle().fill(Theme.aurora).frame(width: size, height: size)
            case .neutral: Circle().fill(Theme.neutralDot).frame(width: size, height: size)
            case .preparing: PreparingDot(size: size)
            case .problem:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: size * 1.4, weight: .semibold))
                    .foregroundStyle(Theme.ember)
            }
        }
        .frame(width: size * 1.8, height: size * 1.8)
        .accessibilityHidden(true)
    }
}

public extension EnvironmentValues {
    /// Holds the clock-driven animations (the preparing dot's breath, the glacier line's travel) still at this point
    /// of their period, from 0 to 1; nil lets them run. The snapshot scenes set it, so no picture depends on the
    /// moment it was rendered.
    @Entry var frozenAnimationPhase: Double? = nil
}

/// A glacier dot with a soft halo that swells and fades on the wait's rhythm. With Reduce Motion it stands still.
private struct PreparingDot: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.frozenAnimationPhase) private var frozenPhase

    var body: some View {
        if reduceMotion {
            dot(phase: 0.5)
        } else if let frozenPhase {
            dot(phase: 0.5 - 0.5 * cos(2 * .pi * frozenPhase))
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                let period = 1.1
                let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                dot(phase: 0.5 - 0.5 * cos(2 * .pi * t))
            }
        }
    }

    private func dot(phase: Double) -> some View {
        ZStack {
            Circle().fill(Theme.glacier.opacity(0.28 * (1 - phase)))
                .frame(width: size * (1 + 0.8 * phase), height: size * (1 + 0.8 * phase))
            Circle().fill(Theme.glacier).frame(width: size, height: size)
                .opacity(0.75 + 0.25 * phase)
        }
    }
}

/// A thin glacier line for work in progress: the model preparing, a Run Log entry transcribed again. Without a
/// fraction a short segment travels along it; with Reduce Motion the segment rests in the middle.
public struct GlacierBar: View {
    private let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.frozenAnimationPhase) private var frozenPhase

    /// A line filled to `fraction` from 0 to 1, or travelling without one.
    public init(fraction: Double? = nil) {
        self.fraction = fraction
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                if let fraction {
                    Capsule().fill(Theme.glacier)
                        .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
                } else if reduceMotion {
                    Capsule().fill(Theme.glacier).frame(width: proxy.size.width * 0.25)
                        .offset(x: proxy.size.width * 0.375)
                } else if let frozenPhase {
                    Capsule().fill(Theme.glacier).frame(width: proxy.size.width * 0.25)
                        .offset(x: proxy.size.width * (-0.25 + 1.25 * frozenPhase))
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                        let period = 1.6
                        let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
                            / period
                        Capsule().fill(Theme.glacier).frame(width: proxy.size.width * 0.25)
                            .offset(x: proxy.size.width * (-0.25 + 1.25 * t))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// A state's words with its mark before them: "● Ready".
public struct StatusLabel: View {
    private let line: StatusLine
    private let font: Font

    /// `line`'s mark and words, in `font`.
    public init(_ line: StatusLine, font: Font = .system(size: 12, weight: .medium)) {
        self.line = line
        self.font = font
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 6) {
            StatusIndicator(line.indicator)
            Text(line.text)
                .font(font)
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.text)
    }
}
