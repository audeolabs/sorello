import AppKit
import CoreText
import SwiftUI
import Testing
@testable import SorelloUI

/// Display text is Urbanist Medium, tracked in by 0.015 em (ARCHITECTURE.md, section 8), from the font the
/// repository ships.
@MainActor
struct DisplayTypeTests {
    @Test func displayTextIsSetInUrbanistMedium() {
        Resources.registerFonts()
        for type in [DisplayType.screenTitle, .stepTitle, DisplayType(size: 52)] {
            #expect(type.face.fontName == "Urbanist-Medium")
            #expect(type.face.fontName != NSFont.systemFont(ofSize: type.size, weight: .medium).fontName)
            #expect(type.face.pointSize == type.size)
        }
    }

    @Test func theFontsThatShipAreUrbanistMediumAndItsLicence() throws {
        let fonts = try #require(Resources.directory).appendingPathComponent("Fonts", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: fonts.path).filter { !$0.hasPrefix(".") }
        #expect(files.sorted() == ["Urbanist-Medium.ttf", "Urbanist-OFL.txt"])

        let face = fonts.appendingPathComponent("Urbanist-Medium.ttf")
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(face as CFURL) as? [CTFontDescriptor] ?? []
        let names = descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
        #expect(names == ["Urbanist-Medium"])

        let licence = try String(contentsOf: fonts.appendingPathComponent("Urbanist-OFL.txt"), encoding: .utf8)
        #expect(licence.contains("Copyright 2021 The Urbanist Project Authors"))
        #expect(licence.contains("SIL OPEN FONT LICENSE Version 1.1"))
    }

    /// The tracking comes with the face: text set as display text is narrower than the same face set plainly, by
    /// 0.015 em for each letter.
    @Test func displayTextIsTrackedIn() {
        Resources.registerFonts()
        let type = DisplayType(size: 40)
        let word = "Sorello"
        let tracked = NSHostingView(rootView: Text(verbatim: word).displayType(type)).fittingSize.width
        let plain = NSHostingView(rootView: Text(verbatim: word).font(Font(type.face as CTFont))).fittingSize.width
        let perLetter = 0.015 * type.size
        #expect(type.tracking == -perLetter)
        let narrower = plain - tracked
        #expect(narrower >= perLetter * CGFloat(word.count - 1) - 0.5, "\(narrower) points narrower")
        #expect(narrower <= perLetter * CGFloat(word.count) + 0.5, "\(narrower) points narrower")
    }
}
