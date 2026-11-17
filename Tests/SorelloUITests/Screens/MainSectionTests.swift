import SwiftUI
import Testing
@testable import SorelloUI

/// ARCHITECTURE.md, section 8, "Windows", Main window: the sidebar's sections, in order, each reached with ⌘ and its
/// place in the list.
@MainActor
struct MainSectionTests {
    @Test func theSidebarListsTranscribeAmongTheSections() {
        #expect(MainSection.allCases.map(\.title)
                == ["General", "Shortcuts", "Dictionary", "Macros", "Transcribe", "Run Log", "About"])
        #expect(MainSection.allCases.map(\.keyEquivalent.character) == ["1", "2", "3", "4", "5", "6", "7"])
    }

    /// The screen is titled as its row is.
    @Test func theTranscribeScreenIsTitledAsItsRow() {
        #expect(TranscribeWords.title == MainSection.transcribe.title)
    }
}
