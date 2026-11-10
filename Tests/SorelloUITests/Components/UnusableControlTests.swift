import AppKit
import DesignCore
import SwiftUI
import Testing
@testable import SorelloUI

/// A control that cannot be used says so by how it looks (ARCHITECTURE.md, section 8): Sorello dims it, and dims a text
/// field's placeholder and text with it, whatever SDK the app records. Each test renders a control the app uses off
/// screen, on a card, once usable and once not, and compares how much it draws above its own background.
@MainActor
struct UnusableControlTests {
    /// The most of its usable ink a control that cannot be used may keep. A field the system left undimmed keeps all
    /// of it (1.0); the system's own dimming, for an app that recorded SDK 26, kept 0.53; Sorello's keeps less than
    /// half. A rendering difference of a few levels moves the ratio by a few hundredths.
    static let mostInkKept = 0.75

    @Test(arguments: UnusableControl.allCases)
    func aControlThatCannotBeUsedIsClearlyDimmer(control: UnusableControl) throws {
        let usable = try control.ink(enabled: true)
        let unusable = try control.ink(enabled: false)
        try #require(usable > 20, "nothing drawn on the usable \(control)")
        let kept = unusable / usable
        #expect(kept <= Self.mostInkKept,
                "\(control) keeps \(String(format: "%.3f", kept)) of its ink: \(Int(unusable)) of \(Int(usable))")
    }
}

/// The controls the app shows as unusable, each as a screen draws it.
enum UnusableControl: String, CaseIterable, CustomTestStringConvertible {
    /// The Dictionary's add field, empty, showing its placeholder.
    case fieldPlaceholder
    /// The same field holding a word.
    case fieldText
    /// The add card's strength presets.
    case strengthPresets
    /// A word's strength menu.
    case strengthMenu
    /// The add card's "Use in" menu.
    case appsMenu
    /// A word's apps menu, as its glyph.
    case appsGlyphMenu
    /// The main action beside a field.
    case primaryButton
    /// A quieter action.
    case quietButton
    /// A glyph-only action, such as delete.
    case glyphButton
    /// Sorello's switch.
    case sorelloSwitch

    var testDescription: String { rawValue }

    private static let size = CGSize(width: 420, height: 48)
    /// Where the field is drawn: 10 pt in from the corner, 280 by `Metrics.fieldHeight`.
    @MainActor private static var field: CGRect { CGRect(x: 10, y: 10, width: 280, height: Metrics.fieldHeight) }

    @MainActor @ViewBuilder
    private var view: some View {
        switch self {
        case .fieldPlaceholder:
            SorelloTextField("Word or phrase", text: .constant("")).frame(width: Self.field.width)
        case .fieldText:
            SorelloTextField("Word or phrase", text: .constant("Quillmoor")).frame(width: Self.field.width)
        case .strengthPresets:
            PresetPicker("Strength", options: StrengthPresets.values, selection: .constant(StrengthPresets.defaultValue),
                         label: StrengthPresets.label)
        case .strengthMenu:
            StrengthMenu(strength: 2) { _ in }
        case .appsMenu:
            AppLimitMenu(selected: [], knownApps: [], set: { _ in }, chooseOther: {})
        case .appsGlyphMenu:
            AppLimitMenu(selected: [], knownApps: [], compact: true, set: { _ in }, chooseOther: {})
        case .primaryButton:
            Button("Add") {}.buttonStyle(PrimaryButtonStyle())
        case .quietButton:
            Button("Cancel") {}.buttonStyle(QuietButtonStyle())
        case .glyphButton:
            Button {} label: { Image(systemName: "trash") }.buttonStyle(IconButtonStyle(destructive: true))
        case .sorelloSwitch:
            Toggle(isOn: .constant(false)) { EmptyView() }.toggleStyle(.sorello).frame(width: 60)
        }
    }

    /// What is measured, in points: inside the field's edge for the field, so only its placeholder or text counts;
    /// the whole picture otherwise.
    @MainActor private var measured: CGRect {
        switch self {
        case .fieldPlaceholder, .fieldText: Self.field.insetBy(dx: 6, dy: 4)
        default: CGRect(origin: .zero, size: Self.size)
        }
    }

    /// How much the control draws above its own background inside `measured`: each pixel's lightness above the
    /// commonest one there, summed.
    @MainActor func ink(enabled: Bool) throws -> Double {
        let scale: CGFloat = 2
        let scene = SnapshotScene(name: "unusable-\(rawValue)", size: Self.size, background: Palette.card) {
            view
                .disabled(!enabled)
                .padding(.leading, Self.field.minX)
                .padding(.top, Self.field.minY)
                .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        }
        let png = try #require(SnapshotRenderer.png(of: scene, scale: scale))
        let bitmap = try #require(NSBitmapImageRep(data: png))
        let box = measured
        var lightness: [Double] = []
        var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        for y in Int(box.minY * scale) ..< Int(box.maxY * scale) {
            for x in Int(box.minX * scale) ..< Int(box.maxX * scale) {
                bitmap.getPixel(&pixel, atX: x, y: y)
                lightness.append(Double(pixel[0] + pixel[1] + pixel[2]) / 3 / 255)
            }
        }
        var counts: [Int: Int] = [:]
        for value in lightness { counts[Int((value * 255).rounded()), default: 0] += 1 }
        let background = Double(try #require(counts.max { $0.value < $1.value }).key) / 255
        return lightness.reduce(0) { $0 + max(0, $1 - background) }
    }
}
