import Testing
@testable import SorelloUI

/// About's promise (ARCHITECTURE.md, section 9, invariant 1): what is said stays on the Mac, and the app says which
/// one thing it connects for. It must not say the app makes no connection: it downloads its speech model.
struct AboutCopyTests {
    @Test func thePromiseIsAboutWhatIsSaidAndNamesTheOneConnection() {
        #expect(AboutCopy.privacyTitle == "Nothing you say leaves this Mac.")
        #expect(AboutCopy.privacyDetail(appName: "Sorello")
                == "Speech is recognised here, and the Run Log, the dictionary and your settings stay here. Sorello connects to the network only to download its speech model.")
    }
}
