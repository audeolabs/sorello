import AppKit
import DesignCore

/// The pill's type, in one place: the elapsed time in monospaced digits so it never jitters, the words of the wait
/// and the notice's line, and the actions' titles.
enum PillType {
    static let time = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    static let words = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let notice = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let action = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let symbolSize: CGFloat = 14
    static let tagSize: CGFloat = 10
    /// The gap between the prompt tag and the time.
    static let tagGap: CGFloat = 5
    /// A capsule action: its height and the padding either side of its title.
    static let actionHeight: CGFloat = 26
    static let actionPadding: CGFloat = 13

    static func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The height of one line of `font`, from its descender to its ascender.
    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender) }
}

/// One control the pill offers, where it is in the screen's points (top left, y down), and what VoiceOver calls it.
struct PillControl: Equatable {
    enum Kind: Equatable {
        case stop
        case cancel
        case action(notice: UInt64, id: String)
    }

    var kind: Kind
    var frame: CGRect
    var label: String
}

/// Everything the pill needs to draw one display on one screen: its form, the geometry for it, the notice's inner
/// layout, and the controls. Computed in one place so what is drawn and what takes clicks always agree.
struct PillScene: Equatable {
    var display: PillDisplay
    var layout: PillLayout
    var notice: NoticeLayout?
    var controls: [PillControl]

    /// The form to draw; hidden draws the housing's own footprint.
    static func form(for display: PillDisplay, on screen: ScreenTopology) -> PillForm {
        switch display {
        case .hidden:
            return .rest
        case .listening(let listening):
            return .listening(trailing: Double(timeContentWidth(prompt: listening.promptStyle)),
                              cancel: listening.trigger == .toggle)
        case .waiting(.transcribing):
            return .waiting(trailing: nil)
        case .waiting(.preparingModel):
            return .waiting(trailing: Double(PillType.width(of: preparingText, font: PillType.words)))
        case .notice(let notice):
            return .notice(noticeLayout(notice, on: screen).size)
        }
    }

    init(display: PillDisplay, screen: ScreenTopology, adjustments: PillAdjustments) {
        self.display = display
        layout = PillGeometry.layout(Self.form(for: display, on: screen), on: screen, adjustments: adjustments)
        notice = nil
        controls = []
        switch display {
        case .listening(let listening) where listening.trigger == .toggle:
            controls.append(PillControl(kind: .stop, frame: layout.body.frame,
                                        label: String(localized: "Stop dictation")))
            if let cancel = layout.cancel {
                controls.append(PillControl(kind: .cancel, frame: cancel, label: String(localized: "Cancel dictation")))
            }
        case .notice(let value):
            let inner = Self.noticeLayout(value, on: screen)
            notice = inner
            if let card = layout.card {
                for (action, rect) in zip(value.actions, inner.actions) {
                    controls.append(PillControl(kind: .action(notice: value.id, id: action.id),
                                                frame: rect.offsetBy(dx: card.minX, dy: card.minY),
                                                label: action.title))
                }
            }
        default:
            break
        }
    }

    static var preparingText: String { String(localized: "Preparing model") }

    /// The trailing wing's content while listening: the widest time it will show, and the tag before it.
    static func timeContentWidth(prompt: Bool) -> CGFloat {
        let time = PillType.width(of: "00:00", font: PillType.time)
        return prompt ? time + PillType.tagSize + PillType.tagGap + 2 : time
    }

    static func noticeLayout(_ notice: PillDisplay.Notice, on screen: ScreenTopology) -> NoticeLayout {
        let lineHeight = PillType.lineHeight(PillType.notice)
        let actions = notice.actions.prefix(NoticeLayout.maximumActions).map {
            CGSize(width: PillType.width(of: $0.title, font: PillType.action) + 2 * PillType.actionPadding,
                   height: PillType.actionHeight)
        }
        return NoticeLayout(symbol: CGSize(width: PillType.symbolSize + 4, height: PillType.symbolSize + 4),
                            text: CGSize(width: PillType.width(of: notice.text, font: PillType.notice),
                                         height: lineHeight),
                            actions: Array(actions), maxWidth: PillGeometry.maximumCardContent(on: screen),
                            scale: screen.scale)
    }

    /// The elapsed time as the pill shows it: minutes and seconds, "0:07", "12:30".
    static func elapsedText(_ seconds: TimeInterval) -> String {
        let whole = seconds.isFinite ? max(Int(seconds.rounded(.down)), 0) : 0
        let tens = whole % 60 / 10, ones = whole % 10
        return "\(whole / 60):\(tens)\(ones)"
    }
}
